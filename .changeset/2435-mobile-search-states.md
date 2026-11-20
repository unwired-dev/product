---
'@private-email/mobile': patch
---

On iPhone and iPad, a search that matches nothing shows the **No Results** state: centred on iPhone with its icon tile above "No mail saved on this device matches “…”", and at the top of iPad's list naming the scope and the query. While the mail servers are searched, an activity indicator stands above "Searching All Inboxes…" on iPhone, naming the shown scope, and above the mailboxes searched on iPad, as in "Searching All Mailboxes…". No Results waits until the list has listed and the mail servers have answered completely (#2435, part of #2090).
