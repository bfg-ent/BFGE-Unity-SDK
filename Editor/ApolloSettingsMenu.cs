using System.Collections.Generic;
using System.IO;
using BFG.Editor.Data;
using UnityEditor;
using UnityEngine;

namespace BFG.Apollo.EditorTools
{
    /// <summary>
    /// One-step creation of every settings file the Apollo SDK loads from <c>Resources</c> at
    /// <c>Initialize()</c>: <c>BfgSettings.asset</c>, <c>BfgFirebaseSettings.asset</c>,
    /// <c>BfgConsent.asset</c>, <c>ApolloNetworkConfig.json</c> and <c>ApolloConsentConfig.json</c>.
    /// </summary>
    /// <remarks>
    /// This file ships inside the Apollo package (copy-apollo-dlls.sh copies it into
    /// Apollo-Package/Editor/, where Bfg.Apollo.Editor.asmdef compiles it against the precompiled
    /// Bfg.Apollo.dll), so the menu is available in every integrating game as well as in this repo.
    /// It must therefore only reference types that are public in the shipped DLL.
    ///
    /// "Missing" is decided with <c>Resources.Load</c> — the exact lookup the SDK performs at
    /// runtime — so a file that already exists in ANY Resources folder is left alone and no
    /// ambiguous duplicate is ever created. Missing files are created under Assets/Resources:
    /// ScriptableObject assets with their class defaults, JSON files from the production-URL
    /// templates below (switch the URLs to the test endpoints during development).
    /// </remarks>
    public static class ApolloSettingsMenu
    {
        private const string ResourcesFolder = "Assets/Resources";

        // Production endpoints. Test equivalents (development/QA builds):
        //   events:  https://test.mobile.bigfishgames.com/events/
        //   policy:  https://test.policy.bigfishgames.com
        // MessageTypes 5 (BFGCustomEvent) and 7 (InternetConnectionCheck) deliberately have no
        // entry — nothing dispatches them (see APOLLO_SDK_INTEGRATION_GUIDE.md).
        private const string NetworkConfigTemplate = @"{
    ""ConfigItems"": [
        {
            ""MessageType"": 0,
            ""UrlRoot"": ""https://mobile.bigfishgames.com/events/"",
            ""Version"": ""/2.2.0""
        },
        {
            ""MessageType"": 1,
            ""UrlRoot"": ""https://mobile.bigfishgames.com/events/"",
            ""Version"": ""/2.2.0""
        },
        {
            ""MessageType"": 2,
            ""UrlRoot"": ""https://mobile.bigfishgames.com/events/"",
            ""Version"": ""/2.2.0""
        },
        {
            ""MessageType"": 3,
            ""UrlRoot"": ""https://mobile.bigfishgames.com/events/"",
            ""Version"": ""/2.2.0""
        },
        {
            ""MessageType"": 4,
            ""UrlRoot"": ""https://mobile.bigfishgames.com/events/"",
            ""Version"": ""/2.2.0""
        },
        {
            ""MessageType"": 6,
            ""UrlRoot"": ""https://mobile.bigfishgames.com/events/"",
            ""Version"": ""/2.2.0""
        },
        {
            ""MessageType"": 8,
            ""UrlRoot"": ""https://policy.bigfishgames.com/consent-reporting/mobile/v1"",
            ""Version"": """",
            ""AppendProductVersionSuffix"": false
        }
    ]
}
";

        private const string ConsentConfigTemplate = @"{
    ""PolicyServiceUrlRoot"": ""https://policy.bigfishgames.com""
}
";

        [MenuItem("BFG/Apollo/Create Missing Settings Files")]
        public static void CreateMissingSettingsFiles()
        {
            var created = new List<string>();
            var skipped = new List<string>();

            CreateAssetIfMissing<GameInfos>("BfgSettings", created, skipped);
            CreateAssetIfMissing<FirebaseSettings>("BfgFirebaseSettings", created, skipped);
            CreateAssetIfMissing<ConsentSettings>("BfgConsent", created, skipped);
            CreateJsonIfMissing("ApolloNetworkConfig", NetworkConfigTemplate, created, skipped);
            CreateJsonIfMissing("ApolloConsentConfig", ConsentConfigTemplate, created, skipped);

            if (created.Count > 0)
            {
                AssetDatabase.SaveAssets();
                AssetDatabase.Refresh();
                Debug.Log($"[Apollo] Created {created.Count} settings file(s) in {ResourcesFolder}: "
                          + string.Join(", ", created)
                          + ". Fill in the asset fields in the Inspector. The JSON templates point at the "
                          + "PRODUCTION endpoints — switch to the test URLs for development/QA builds "
                          + "(see APOLLO_SDK_INTEGRATION_GUIDE.md).");

                var folder = AssetDatabase.LoadAssetAtPath<Object>(ResourcesFolder);
                if (folder != null)
                {
                    Selection.activeObject = folder;
                    EditorGUIUtility.PingObject(folder);
                }
            }

            if (skipped.Count > 0)
            {
                Debug.Log($"[Apollo] Already present (skipped): {string.Join(", ", skipped)}");
            }
        }

        private static void CreateAssetIfMissing<T>(string resourceName, List<string> created, List<string> skipped)
            where T : ScriptableObject
        {
            if (Resources.Load<T>(resourceName) != null)
            {
                skipped.Add($"{resourceName}.asset");
                return;
            }

            EnsureResourcesFolder();
            var asset = ScriptableObject.CreateInstance<T>();
            AssetDatabase.CreateAsset(asset, $"{ResourcesFolder}/{resourceName}.asset");
            created.Add($"{resourceName}.asset");
        }

        private static void CreateJsonIfMissing(string resourceName, string template, List<string> created, List<string> skipped)
        {
            if (Resources.Load<TextAsset>(resourceName) != null)
            {
                skipped.Add($"{resourceName}.json");
                return;
            }

            EnsureResourcesFolder();
            var path = $"{ResourcesFolder}/{resourceName}.json";
            File.WriteAllText(path, template);
            AssetDatabase.ImportAsset(path);
            created.Add($"{resourceName}.json");
        }

        private static void EnsureResourcesFolder()
        {
            if (!Directory.Exists(ResourcesFolder))
            {
                Directory.CreateDirectory(ResourcesFolder);
                AssetDatabase.Refresh();
            }
        }
    }
}
