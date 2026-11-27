---
'@private-email/mobile': patch
---

On iPhone and iPad, the Move picker's Back, Close and Cancel, and the iPad popover's selectable folder rows, are system buttons, so VoiceOver reads each as one button and the system draws the press feedback (#3073).

At the largest text sizes, and after the text size changes while they are open, the Move picker's rows and the Settings action rows fit their labels, truncating a long name with an ellipsis instead of clipping it.
