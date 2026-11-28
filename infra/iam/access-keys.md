# Entering an access key safely

`aws configure --profile <name>` echoes both key values into the terminal — they land in
scrollback (and any multiplexer history). Prefer the non-echoing form:

```bash
aws configure set aws_access_key_id <ID> --profile <name>
aws configure set aws_secret_access_key <SECRET> --profile <name>
```

If the interactive form was already used, clear the pane history afterwards (e.g.
`tmux clear-history -t <session>`) and rotate the key if the screen was shared.
