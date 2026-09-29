# Apple client localization

The iPhone app, Watch app, widget extension, and shared Live Activity package each own a `Localizable.xcstrings` catalog. The iPhone app also has `InfoPlist.xcstrings` for its camera permission prompt. English is the source language; every manually defined key has English and Finnish text and a translator comment.

At user-facing call sites, pass translator context through the localization API's `comment:` argument. Use SwiftUI's `Text("locAddBaby", comment: "Action to add a child to the family")` for text views, and `LocalizedStringResource("locAddBaby", defaultValue: "Add baby", comment: "Action to add a child to the family")` for controls and strings that take a resource. Xcode's generated resource members do not accept a call-site comment; use them for formatted strings whose catalog entries already carry translator context. For formatted strings, define one catalog entry with `%@` placeholders in the order the values should appear, then call its generated function. Keep persistent role codes, database values, URLs, and system image names as stable strings.

Unexpected technical errors use a localized generic fallback rather than displaying a raw backend or framework message. Keep actionable validation and recovery messages as their own catalog entries.

Xcode generates the app, Watch, and widget symbols while building. Swift Package Manager does not generate the symbols for `UnetonActivity`; after editing its catalog, regenerate and commit its source file:

```sh
xcrun xcstringstool generate-symbols clients/ios/UnetonPackage/Sources/UnetonActivity/Localizable.xcstrings \
  --output-directory clients/ios/UnetonPackage/Sources/UnetonActivity --language swift
```

After changing catalogs or call sites, run `python3 clients/ios/scripts/check_localizations.py`, regenerate the Xcode project with `mise run project` when adding a catalog or source file, and run the iPhone test suite. `LocalizationTests` checks resource lookup and interpolation in both languages.
