# TODO

## Native shared statusline renderer

Revisit replacing the Claude and Codex shell renderers with one small native
renderer (Rust or Go) after the shared lazy-cache design is implemented and
measured. The potential benefit is avoiding Bash, `jq`, `date`, and other
per-render subprocess startup while keeping provider-specific payload adapters
and a common formatter. Do not pursue this until measurements show that the
shell implementation remains material at the desired refresh frequency


## 7d rendering bug in Codex

I sometimes see:
```
7d [█████░░░]o69%
```
In the statusline in Codex. Why is that? What is this "o" charactere? Investigate
