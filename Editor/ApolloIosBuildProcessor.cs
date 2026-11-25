#if UNITY_IOS
using System;
using System.Collections.Generic;
using System.IO;
using UnityEditor;
using UnityEditor.Build;
using UnityEditor.Build.Reporting;
using UnityEditor.iOS.Xcode;
using UnityEngine;

namespace BFG.Apollo.EditorTools
{
    /// <summary>
    /// Writes the Firebase Analytics Consent Mode defaults into the exported Xcode project's Info.plist
    /// and strips the legacy collection kill switch, on every iOS export.
    /// </summary>
    /// <remarks>
    /// This file ships inside the Apollo package (copy-apollo-dlls.sh copies it into the package's
    /// Editor/ folder, where Bfg.Apollo.Editor.asmdef compiles it); in this repo it compiles under
    /// Bfg.Apollo.EditorBuild.asmdef. It must therefore use only Unity/editor/.NET types — no SDK internals.
    ///
    /// Apollo applies the GDPR decision at runtime through <c>FirebaseAnalytics.SetConsent</c>
    /// (Consent Mode), which needs Firebase to initialize at launch, so:
    /// <list type="bullet">
    /// <item><c>FIREBASE_ANALYTICS_COLLECTION_ENABLED</c> is removed (it shuts Firebase down at launch).</item>
    /// <item>A Boolean-false <c>GOOGLE_ANALYTICS_DEFAULT_ALLOW_ANALYTICS_STORAGE</c> is rewritten to true —
    /// earlier Apollo guidance (Android) set analytics_storage to false, which would keep it denied for
    /// every user; a game post-process that copied that advice is corrected the same way.</item>
    /// <item>Missing defaults are added: <c>GOOGLE_ANALYTICS_DEFAULT_ALLOW_ANALYTICS_STORAGE</c> and
    /// <c>..._AD_STORAGE</c> Boolean YES; <c>..._AD_USER_DATA</c> and <c>..._AD_PERSONALIZATION_SIGNALS</c>
    /// String <c>eu_consent_policy</c> (denied by default only in EEA regions).</item>
    /// </list>
    /// Every other game-provided value is kept, Crashlytics keys are never touched, and the processor is
    /// idempotent (Append builds). <c>callbackOrder</c> 999 runs after typical game post-processors
    /// (<c>[PostProcessBuild]</c> defaults to 1); one ordered above that which writes the kill switch wins,
    /// so the exported Info.plist is the authoritative check. Same rules as BFGSDKPub's
    /// IosBuildProcessor.ApplyFirebaseAnalyticsConsentDefaults.
    /// </remarks>
    public class ApolloIosBuildProcessor : IPostprocessBuildWithReport
    {
        public const string KillSwitchKey = "FIREBASE_ANALYTICS_COLLECTION_ENABLED";
        public const string AnalyticsStorageKey = "GOOGLE_ANALYTICS_DEFAULT_ALLOW_ANALYTICS_STORAGE";
        public const string AdStorageKey = "GOOGLE_ANALYTICS_DEFAULT_ALLOW_AD_STORAGE";
        public const string AdUserDataKey = "GOOGLE_ANALYTICS_DEFAULT_ALLOW_AD_USER_DATA";
        public const string AdPersonalizationKey = "GOOGLE_ANALYTICS_DEFAULT_ALLOW_AD_PERSONALIZATION_SIGNALS";

        private const string EuConsentPolicy = "eu_consent_policy";
        private const string LogPrefix = "[Apollo Build] ";

        public int callbackOrder => 999;

        /// <summary>What <see cref="ApplyConsentDefaults"/> changed.</summary>
        public sealed class Result
        {
            /// <summary>Corrections to game-provided entries (kill switch removed, legacy false rewritten).</summary>
            public readonly List<string> Warnings = new List<string>();
            /// <summary>Default keys added to Info.plist.</summary>
            public readonly List<string> Added = new List<string>();
            public bool Changed;
        }

        public void OnPostprocessBuild(BuildReport report)
        {
            if (report.summary.platform != BuildTarget.iOS) return;

            var plistPath = Path.Combine(report.summary.outputPath, "Info.plist");
            if (!File.Exists(plistPath))
            {
                Debug.LogWarning($"{LogPrefix}Info.plist not found at '{plistPath}'; Firebase Consent Mode defaults were not applied.");
                return;
            }

            var plist = new PlistDocument();
            plist.ReadFromFile(plistPath);

            var result = ApplyConsentDefaults(plist);

            foreach (var warning in result.Warnings)
            {
                Debug.LogWarning(LogPrefix + warning);
            }

            if (result.Changed) plist.WriteToFile(plistPath);

            Debug.Log(result.Added.Count > 0
                ? $"{LogPrefix}Firebase Consent Mode defaults added to Info.plist: {string.Join(", ", result.Added)}"
                : $"{LogPrefix}Firebase Consent Mode defaults already present.");
        }

        /// <summary>Applies the Consent Mode rules to the plist in place (see the class remarks).</summary>
        public static Result ApplyConsentDefaults(PlistDocument plist)
        {
            if (plist?.root == null) throw new ArgumentNullException(nameof(plist));

            var result = new Result();
            var values = plist.root.values;

            if (values.Remove(KillSwitchKey))
            {
                result.Changed = true;
                result.Warnings.Add($"Removed {KillSwitchKey} from Info.plist: it shuts Firebase down at launch and defeats " +
                                    "Consent Mode (Apollo applies GDPR consent via FirebaseAnalytics.SetConsent).");
            }

            if (values.TryGetValue(AnalyticsStorageKey, out var analyticsStorage)
                && analyticsStorage is PlistElementBoolean storageFlag && !storageFlag.value)
            {
                plist.root.SetBoolean(AnalyticsStorageKey, true);
                result.Changed = true;
                result.Warnings.Add($"Rewrote {AnalyticsStorageKey} NO to YES in Info.plist: a false default would keep " +
                                    "analytics_storage denied for every user under Consent Mode.");
            }

            SetBooleanIfAbsent(plist, AnalyticsStorageKey, true, result);
            SetBooleanIfAbsent(plist, AdStorageKey, true, result);
            SetStringIfAbsent(plist, AdUserDataKey, EuConsentPolicy, result);
            SetStringIfAbsent(plist, AdPersonalizationKey, EuConsentPolicy, result);

            return result;
        }

        private static void SetBooleanIfAbsent(PlistDocument plist, string key, bool value, Result result)
        {
            if (plist.root.values.ContainsKey(key)) return;
            plist.root.SetBoolean(key, value);
            result.Added.Add(key);
            result.Changed = true;
        }

        private static void SetStringIfAbsent(PlistDocument plist, string key, string value, Result result)
        {
            if (plist.root.values.ContainsKey(key)) return;
            plist.root.SetString(key, value);
            result.Added.Add(key);
            result.Changed = true;
        }
    }
}
#endif
