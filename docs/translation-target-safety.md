# Input target safety (issue #6)

`UITextDocumentProxy.documentIdentifier` is documented as identifying a document, not as proof of a particular field or every focus transition. UIKit's input delegate offers text/selection callbacks, but the referenced documentation does not promise that every host or reconstruction reports all field changes. No host text is used for identity.

Each automatic delivery is bound to a request ID, document ID, visibility, connection and an invalidation epoch. Keyboard appearance/disappearance, connection state changes and text/selection callbacks invalidate the epoch; an attempt consumes its binding once. The guard additionally requires explicit verified continuity. The current iOS integration cannot establish that assurance and deliberately does not set it. Consequently both translation and ordinary dictation are held for explicit insertion into the current field in this checkpoint. A simulated verified-continuity source can exercise direct insertion, but is not an iOS claim. Actual translation service remains disabled.

Held dictation is stored locally and pauses subsequent delivery until the user explicitly inserts it. A blocked translation remains available for explicit current-field insertion or an explicit decision to skip that insertion; subsequent results wait. Insertion through `UITextDocumentProxy` has no delivery acknowledgement. Explicit recovery does not prove that the current field is the original field. Host app history remains the recovery fallback for process or transport failures.

Before enabling direct delivery, demonstrate a supported identity/continuity mechanism and test multiple real hosts, identical field contents, focus changes with/without callbacks, selection movement, reconnect, process death and keyboard reconstruction. Xcode compilation and real-device validation have not been performed.

Apple references:
- https://developer.apple.com/documentation/uikit/uitextdocumentproxy/documentidentifier
- https://developer.apple.com/documentation/uikit/uitextinputdelegate
- https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/CustomKeyboard.html
