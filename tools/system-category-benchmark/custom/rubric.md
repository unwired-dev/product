# Custom Category labeling rubric (labels v1)

Each message is judged against every Custom Category in
[categories-v1.json](categories-v1.json) independently. A message may belong to
zero, one or several Custom Categories. Membership in a System Category neither
implies nor excludes a Custom Category.

- Judge each category by its English name **and** description together; the
  description is the user's guidance and governs when the name alone is
  ambiguous (for example "Statements" excludes press statements and "Club"
  excludes nightclubs). The Czech names, descriptions and paraphrases mean the
  same thing and do not change the label.
- Decide from the sender, recipients, mailing-list headers, subject and body,
  as the recipient would read the message. Judge what the message is about and
  what it asks of the recipient, not isolated words: a casual mention of a flight
  in a personal note is not "My flights", and an all-staff memo that mentions a
  party is not "Parties" unless it invites people to one.
- Label a category only when the user who wrote that description would clearly
  want this message filed there. When it is doubtful, leave it out.
- Forwarded messages are judged by the forwarded content and the forwarder's
  note together.
- Do not label from the source or the stratum: Enron work mail can be "Family and
  friends" when it is a private note, and synthetic mail is judged like any other.

Messages that the System Category annotation excluded are not in the corpus.
Labels are agent annotations, not human-verified ground truth.

## Synthetic reconciliation

Synthetic messages rendered from one template received one label set, chosen by
majority across both languages and, on a tie, by the doubt rule above. A slot
value keeps its own labels only when it changes the meaning: a one-to-one lunch
invitation is also "Office social" when the venue is an office room or a video
call, and a reply about meeting notes is "Meetings" only when the notes come from
a work meeting rather than a party.
