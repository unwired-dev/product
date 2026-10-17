# @private-email/draft-editor

## 0.1.0

### Minor Changes

- 02178a0: Extend the registration-draft-editor Tiptap evaluation editor to formatted Drafts: headings, lists, quotes, code and inline marks with Markdown shortcuts, word-step Undo and Redo, an explicit paste policy, and reviewed rewrites, reply suggestions and translations applied as one page edit. Production and other scenarios retain the current composer.

  Return continues bulleted and numbered lists and quotes even on an empty item or line.

  The draft-editor message API replaces `decodeChange` and `change` messages with `decodeUpdate` and revisioned `update` messages carrying selection and formatting state.

- b4a3aae: Open Drafts with Inline Images and Attachments in the registration-draft-editor Tiptap evaluation editor, now laid out as the approved compose design: the current composer's header, sending mailbox, Subject, To, Cc and Bcc and Send around the page's body. iPhone formats from a floating Liquid Glass pill and a Format panel that replaces the keyboard, iPad and Mac keep the format bar, and Writing tools gather Rewrite, Translate and Suggest reply. Nothing is saved until Save Draft (Save on Mac) or Send; Close offers Delete Draft and Save Draft on iPhone and iPad, and the Mac asks whether to save. Images placed inline through the system pickers (and, on iPhone and iPad, Paste Image or a paste into the page) keep their Draft Asset identity through typing, moving, deletion, Undo, Redo, saving and reopening; a row's context menu turns an Inline Image into an Attachment or an image Attachment into an Inline Image as one undoable edit. The page receives only native thumbnails of verified bytes and refuses pasted or dropped files. Production and other scenarios retain the current composer.

  The draft-editor message API replaces `decodeUpdate` with `decodeMessage`, which also decodes the page's `paste` request; `update` messages carry the Draft's Attachments, the page accepts `add`, `remove`, `convert`, `previews`, `focus` and `editable` commands, and `knownAssets` keeps a reported body to the assets the host gave the page. `supported` is removed. Close, Save and Send wait for a read-only page acknowledgement so queued body edits are included; import settlement keeps the saved baseline current, and navigation resumes after Save or Delete.

  The Mac save question keeps background composer controls inactive and hidden from assistive technology, with keyboard focus retained in its choices until Save, Don’t Save or Cancel.

  Save and Send feedback, errors and assistance reviews scroll with the evaluation composer's content so they do not take space permanently from the body in a short window or above the keyboard.

  iPhone floating menus receive taps when they extend over the composer header in landscape.

  Queued toolbar and file actions leave the acknowledged page unchanged while Save or Send finishes, keeping the shown document consistent with the version being stored.

  Evaluation panels finish their closing animation while their controls become inactive immediately. Pending deletion follows the editor's conflicting copy after its window closes. Previously shown inline thumbnails are cleared when native revalidation finds the bytes unavailable.

  On Mac, closing a window with Command-W, its close button or Quit while the evaluation editor is open asks the same save question first instead of losing unsaved edits. Quit continues after each editor allows closing; Cancel or a failed finish keeps the app running.

### Patch Changes

- 3d8b483: Add a locally packaged plain-paragraph Tiptap Draft editor for the isolated registration-draft-editor evaluation scenario, saving through the existing Draft store. Production and other scenarios retain the current composer.
- Updated dependencies [edac772]
- Updated dependencies [b5bd44a]
- Updated dependencies [2b51737]
- Updated dependencies [b9f0c48]
- Updated dependencies [ee99e36]
- Updated dependencies [ee99e36]
- Updated dependencies [ee99e36]
- Updated dependencies [ee99e36]
- Updated dependencies [ee99e36]
- Updated dependencies [a6c02e1]
- Updated dependencies [71e8349]
- Updated dependencies [e4b6969]
- Updated dependencies [b45a92b]
- Updated dependencies [b45a92b]
- Updated dependencies [b45a92b]
- Updated dependencies [b45a92b]
- Updated dependencies [dfc1f46]
- Updated dependencies [dfc1f46]
- Updated dependencies [dfc1f46]
- Updated dependencies [dfc1f46]
- Updated dependencies [f6bf0cb]
- Updated dependencies [1ccb9af]
- Updated dependencies [1ccb9af]
- Updated dependencies [506964e]
- Updated dependencies [8e745d8]
- Updated dependencies [3beb5f5]
- Updated dependencies [3afd931]
- Updated dependencies [a39391a]
- Updated dependencies [0668ad3]
- Updated dependencies [0668ad3]
- Updated dependencies [e135c7c]
- Updated dependencies [02bb862]
- Updated dependencies [ebcb577]
- Updated dependencies [a182684]
- Updated dependencies [a182684]
- Updated dependencies [e9230a2]
- Updated dependencies [e2db13e]
- Updated dependencies [6509f5d]
- Updated dependencies [4a4f5cc]
- Updated dependencies [a285337]
- Updated dependencies [043d25c]
- Updated dependencies [77d3937]
- Updated dependencies [6ee2629]
- Updated dependencies [4ff7648]
- Updated dependencies [452fec1]
- Updated dependencies [ddb3700]
- Updated dependencies [7aba467]
- Updated dependencies [2dae6d7]
- Updated dependencies [01ed01c]
- Updated dependencies [e35b687]
- Updated dependencies [3f028f0]
- Updated dependencies [d802688]
- Updated dependencies [b4a3aae]
- Updated dependencies [36780c7]
- Updated dependencies [d25bf63]
- Updated dependencies [5fc6fc9]
- Updated dependencies [1225b7c]
- Updated dependencies [72a884f]
- Updated dependencies [5e9492b]
- Updated dependencies [8b23735]
- Updated dependencies [648cce3]
- Updated dependencies [a3293d1]
- Updated dependencies [2bd7060]
- Updated dependencies [fab7a42]
- Updated dependencies [fd7bf6b]
- Updated dependencies [1438300]
- Updated dependencies [172b3cc]
- Updated dependencies [b3e892d]
- Updated dependencies [8741a65]
- Updated dependencies [ac2c3e7]
- Updated dependencies [583a0f9]
- Updated dependencies [1276608]
- Updated dependencies [e909300]
- Updated dependencies [a59ebbb]
- Updated dependencies [f7962f2]
- Updated dependencies [76fd227]
- Updated dependencies [8d15586]
- Updated dependencies [84a6f8d]
- Updated dependencies [b45a92b]
- Updated dependencies [b45a92b]
- Updated dependencies [b45a92b]
- Updated dependencies [b45a92b]
- Updated dependencies [dfc1f46]
- Updated dependencies [b45a92b]
- Updated dependencies [b45a92b]
- Updated dependencies [b0b3267]
- Updated dependencies [d4bc7ee]
- Updated dependencies [dfab40f]
- Updated dependencies [262ac82]
- Updated dependencies [7c38123]
- Updated dependencies [819d141]
- Updated dependencies [30b173c]
- Updated dependencies [b45a92b]
- Updated dependencies [30b173c]
- Updated dependencies [15988d9]
- Updated dependencies [7048de3]
- Updated dependencies [b45a92b]
- Updated dependencies [b45a92b]
- Updated dependencies [ed92255]
- Updated dependencies [ee99e36]
- Updated dependencies [b45a92b]
- Updated dependencies [e1d65f9]
- Updated dependencies [9612f48]
- Updated dependencies [b45a92b]
- Updated dependencies [e135c7c]
- Updated dependencies [34651eb]
- Updated dependencies [685494c]
- Updated dependencies [a1bc55d]
- Updated dependencies [2d82cf4]
- Updated dependencies [e4bdb26]
- Updated dependencies [e201a9a]
- Updated dependencies [611c8d3]
- Updated dependencies [6f28fe0]
  - @private-email/mail-core@0.1.0
