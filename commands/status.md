---
description: Check each image provider's API key and whether its model is in the provider's live model list
allowed-tools: Bash(bash */scripts/check-status.sh*)
---

Check the status of the image providers.

## Execution

Run the status check script:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/check-status.sh
```

It sends only GET requests, which cost nothing.

## Output

Show the script output as-is in a code block. It has one row per provider:
- `key`: `not set (<variable>)`, `accepted`, `rejected (HTTP <code>)`, `no answer (curl exit <code>)` or `unexpected HTTP <code>`
- `model listed`: `yes`, `no`, `not checked` when the provider refused or never got the key, or why the script could not read the list
- `model`: the model the provider's script uses, followed by the variable that set it when one did

Below the block, write one line for each row that is not `accepted` and `yes`, naming the fix:
set the variable, replace the rejected key, or set the provider's `*_IMAGE_MODEL` variable to a
model the provider lists. Write nothing else.
