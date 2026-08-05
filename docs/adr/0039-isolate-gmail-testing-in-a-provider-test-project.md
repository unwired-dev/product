# Isolate Gmail testing in a Provider Test Project

Gmail compatibility testing uses a dedicated Provider Test Project with its own OAuth client, Gmail API quotas, Pub/Sub resources, and protected credentials, separate from every production Google Cloud project. Provider-test signals cannot enter production push routes or consume production quotas, and ordinary agents receive commands and redacted Mail Test Evidence rather than reusable Google credentials. This duplicates some provider configuration in exchange for bounded failures, safer automation, and auditable secret access.
