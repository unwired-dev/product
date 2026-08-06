# Use a dedicated Google Workspace test tenant

Gmail compatibility testing uses a dedicated Provider Test Tenant with an internal OAuth application and at least two mail users whose Provider Test Mailboxes contain only Synthetic Test Messages, rather than personal Gmail accounts or an external OAuth application in Testing status. The tenant incurs ongoing cost and administration, but gives scheduled tests stable authorization, controlled identities, realistic Gmail behavior, and a privacy boundary that prevents personal or production mail from entering Provider Test Mailboxes.
