#if UNITY_ANDROID
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Xml.Linq;
using UnityEditor.Android;
using UnityEngine;

namespace BFG.Apollo.EditorTools
{
    /// <summary>
    /// Writes the Firebase Analytics Consent Mode defaults into the generated Gradle project's Android
    /// manifests and strips the legacy collection kill switch, on every Android export.
    /// </summary>
    /// <remarks>
    /// This file ships inside the Apollo package (copy-apollo-dlls.sh copies it into the package's
    /// Editor/ folder, where Bfg.Apollo.Editor.asmdef compiles it); in this repo it compiles under
    /// Bfg.Apollo.EditorBuild.asmdef. It must therefore use only Unity/editor/.NET types — no SDK internals.
    ///
    /// Apollo applies the GDPR decision at runtime through <c>FirebaseAnalytics.SetConsent</c>
    /// (Consent Mode). That only works when Firebase initializes at launch, so:
    /// <list type="bullet">
    /// <item><c>firebase_analytics_collection_enabled</c> is removed (it shuts Firebase down at launch,
    /// losing the Play Billing <c>in_app_purchase</c> observer and the Install Referrer for the session).</item>
    /// <item>A <c>google_analytics_default_allow_analytics_storage</c> of <c>false</c> is rewritten to
    /// <c>true</c> — earlier Apollo guidance told games to add it, which would keep analytics_storage
    /// denied for every user.</item>
    /// <item>Whichever of the four defaults is missing from BOTH manifests is added to unityLibrary's
    /// <c>&lt;application&gt;</c>: analytics_storage and ad_storage <c>true</c>; ad_user_data and
    /// ad_personalization_signals <c>eu_consent_policy</c> (denied by default only in EEA regions).</item>
    /// </list>
    /// Every other game-provided value is kept, Crashlytics flags are never touched, and the processor is
    /// idempotent (Append builds). A key already present in a game's custom <c>LauncherManifest.xml</c>
    /// (the higher-priority launcher module) is not duplicated into unityLibrary, which would be a
    /// manifest-merger conflict. <c>callbackOrder</c> 999 runs after typical game post-processors; one
    /// ordered above that which writes the kill switch wins, so the merged manifest is the authoritative
    /// check.
    /// </remarks>
    public class ApolloAndroidBuildProcessor : IPostGenerateGradleAndroidProject
    {
        public const string KillSwitchKey = "firebase_analytics_collection_enabled";
        public const string AnalyticsStorageKey = "google_analytics_default_allow_analytics_storage";
        public const string AdStorageKey = "google_analytics_default_allow_ad_storage";
        public const string AdUserDataKey = "google_analytics_default_allow_ad_user_data";
        public const string AdPersonalizationKey = "google_analytics_default_allow_ad_personalization_signals";

        private const string LogPrefix = "[Apollo Build] ";

        private static readonly XNamespace Android = "http://schemas.android.com/apk/res/android";

        private static readonly (string Key, string Value)[] Defaults =
        {
            (AnalyticsStorageKey, "true"),
            (AdStorageKey, "true"),
            (AdUserDataKey, "eu_consent_policy"),
            (AdPersonalizationKey, "eu_consent_policy"),
        };

        public int callbackOrder => 999;

        /// <summary>What <see cref="ApplyConsentDefaults"/> changed.</summary>
        public sealed class Result
        {
            /// <summary>Corrections to game-provided entries (kill switch removed, legacy false rewritten).</summary>
            public readonly List<string> Warnings = new List<string>();
            /// <summary>Default keys added to the unityLibrary manifest.</summary>
            public readonly List<string> Added = new List<string>();
            public bool LibraryChanged;
            public bool LauncherChanged;
        }

        /// <param name="path">Root of the generated unityLibrary Gradle module.</param>
        public void OnPostGenerateGradleAndroidProject(string path)
        {
            var libraryPath = Path.Combine(path, "src", "main", "AndroidManifest.xml");
            if (!File.Exists(libraryPath))
            {
                Debug.LogWarning($"{LogPrefix}unityLibrary manifest not found at '{libraryPath}'; Firebase Consent Mode defaults were not applied.");
                return;
            }

            var launcherPath = Path.GetFullPath(Path.Combine(path, "..", "launcher", "src", "main", "AndroidManifest.xml"));
            var library = XDocument.Load(libraryPath, LoadOptions.PreserveWhitespace);
            var launcher = File.Exists(launcherPath) ? XDocument.Load(launcherPath, LoadOptions.PreserveWhitespace) : null;

            var result = ApplyConsentDefaults(library, launcher);

            foreach (var warning in result.Warnings)
            {
                Debug.LogWarning(LogPrefix + warning);
            }

            if (result.LibraryChanged) library.Save(libraryPath);
            if (result.LauncherChanged && launcher != null) launcher.Save(launcherPath);

            Debug.Log(result.Added.Count > 0
                ? $"{LogPrefix}Firebase Consent Mode defaults added to unityLibrary manifest: {string.Join(", ", result.Added)}"
                : $"{LogPrefix}Firebase Consent Mode defaults already present.");
        }

        /// <summary>
        /// Applies the Consent Mode rules to the manifests in place (see the class remarks).
        /// </summary>
        /// <param name="libraryManifest">unityLibrary/src/main/AndroidManifest.xml.</param>
        /// <param name="launcherManifest">launcher/src/main/AndroidManifest.xml, or null when absent.</param>
        public static Result ApplyConsentDefaults(XDocument libraryManifest, XDocument launcherManifest)
        {
            if (libraryManifest?.Root == null) throw new ArgumentNullException(nameof(libraryManifest));

            var result = new Result();
            result.LibraryChanged = CorrectLegacyEntries(libraryManifest, "unityLibrary", result);
            if (launcherManifest?.Root != null)
            {
                result.LauncherChanged = CorrectLegacyEntries(launcherManifest, "launcher", result);
            }

            foreach (var (key, value) in Defaults)
            {
                if (MetaData(libraryManifest, key).Any()) continue;
                if (launcherManifest?.Root != null && MetaData(launcherManifest, key).Any()) continue;

                GetOrCreateApplication(libraryManifest).Add(new XElement("meta-data",
                    new XAttribute(Android + "name", key),
                    new XAttribute(Android + "value", value)));
                result.Added.Add(key);
                result.LibraryChanged = true;
            }

            return result;
        }

        private static bool CorrectLegacyEntries(XDocument manifest, string module, Result result)
        {
            var changed = false;

            foreach (var killSwitch in MetaData(manifest, KillSwitchKey).ToList())
            {
                killSwitch.Remove();
                changed = true;
                result.Warnings.Add($"Removed {KillSwitchKey} from the {module} manifest: it shuts Firebase down at launch " +
                                    "and defeats Consent Mode (Apollo applies GDPR consent via FirebaseAnalytics.SetConsent).");
            }

            foreach (var analyticsStorage in MetaData(manifest, AnalyticsStorageKey))
            {
                var value = analyticsStorage.Attribute(Android + "value");
                if (value == null || !string.Equals(value.Value, "false", StringComparison.OrdinalIgnoreCase)) continue;

                value.Value = "true";
                changed = true;
                result.Warnings.Add($"Rewrote {AnalyticsStorageKey}=\"false\" to \"true\" in the {module} manifest: earlier " +
                                    "Apollo guidance set it to false, which would keep analytics_storage denied for every user under Consent Mode.");
            }

            return changed;
        }

        private static IEnumerable<XElement> MetaData(XDocument manifest, string name) =>
            manifest.Descendants("meta-data").Where(e => (string)e.Attribute(Android + "name") == name);

        private static XElement GetOrCreateApplication(XDocument manifest)
        {
            var application = manifest.Root.Element("application");
            if (application == null)
            {
                application = new XElement("application");
                manifest.Root.Add(application);
            }
            return application;
        }
    }
}
#endif
