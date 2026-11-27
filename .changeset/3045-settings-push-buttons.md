---
'@private-email/mobile': patch
---

On iPhone and iPad, Settings push buttons (such as Add Gmail…, Remove and Allow Notifications) are system buttons, so VoiceOver reads each as one button with its disabled state and the system draws the press feedback. A destructive push button now keeps the quiet fill, as the frames draw it (#3045).
