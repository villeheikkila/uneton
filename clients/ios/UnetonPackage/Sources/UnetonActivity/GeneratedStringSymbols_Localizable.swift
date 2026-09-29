// 
// GeneratedStringSymbols_Localizable.swift
// Auto-Generated symbols for localized strings defined in “Localizable.xcstrings”.
// 

import Foundation

#if SWIFT_PACKAGE
private nonisolated let resourceBundle = Foundation.Bundle.module
@available(macOS 13, iOS 16, tvOS 16, watchOS 9, *)
private nonisolated let resourceBundleDescription = LocalizedStringResource.BundleDescription.atURL(resourceBundle.bundleURL)
#else

private class ResourceBundleClass {}
@available(macOS 13, iOS 16, tvOS 16, watchOS 9, *)
private nonisolated let resourceBundleDescription = LocalizedStringResource.BundleDescription.forClass(ResourceBundleClass.self)
#endif

@available(macOS 13, iOS 16, tvOS 16, watchOS 9, *)
nonisolated extension LocalizedStringResource {
    /**
     Live Activity status; placeholder is the baby’s name.
     
     Localized string for key “locChildIsSleeping” in table “Localizable.xcstrings”.
     */
    static func locChildIsSleeping(_ arg1: String) -> LocalizedStringResource {
        LocalizedStringResource("locChildIsSleeping", defaultValue: "\(arg1)", table: "Localizable", bundle: resourceBundleDescription)
    }

    /**
     Live Activity status followed by the local time when the baby fell asleep.

     Localized string for key “locSleepingSince” in table “Localizable.xcstrings”.
     */
    static func locSleepingSince(_ arg1: String) -> LocalizedStringResource {
        LocalizedStringResource("locSleepingSince", defaultValue: "\(arg1)", table: "Localizable", bundle: resourceBundleDescription)
    }

    /**
     Action in Watch and Live Activity that records that the baby woke up.
     
     Localized string for key “locWakeUp” in table “Localizable.xcstrings”.
     */
    static var locWakeUp: LocalizedStringResource {
        LocalizedStringResource("locWakeUp", table: "Localizable", bundle: resourceBundleDescription)
    }
}