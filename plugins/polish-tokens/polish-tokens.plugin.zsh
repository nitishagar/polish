# polish-tokens: token/cost prompt helpers. Reads ~/.usage/polish/*.json only.
# Parsing lives in bin/polish-tokens-collect (background poller), never here.
polish_tokens_today() {
  if [ -f "$HOME/.usage/polish/daily.json" ]; then
    cat "$HOME/.usage/polish/daily.json"
  else
    echo "no token data yet (run: polish-tokens-collect)"
    return 1
  fi
}
alias pt='polish_tokens_today'
