; Word-attached code spans in tables — tostring column width

Code spans glued to a word or punctuation (`call(`x`)`, `see(``y``)`) are
concealed by the renderer — CommonMark gives code spans no flanking rule, any
backtick pair forms one — so the column-width calculation in
`renderers/markdown/tostring.lua` must account for them too. If it doesn't,
the calculated width differs from what is drawn and the right border drifts
(single-backtick spans happen to line up only because a backtick pair is as
wide as the default padding).

Open this file and check that every right border lines up.

### Code span glued to a word

| Case                            | Example          |
|---------------------------------|------------------|
| After punctuation               | call(`x`) end    |
| Double backticks                | see(``y``) now   |
| Mid-word                        | foo`bar`baz      |
| After a word + space (normal)   | a `code` b       |
| Plain (control)                 | just normal text |

### Mixed with emphasis

| Case                       | Example              |
|----------------------------|----------------------|
| Code inside parentheses    | use (`--quiet`) flag |
| Bold then glued code       | **opt**(`v`) pair    |
| Plain (control)            | nothing here         |
