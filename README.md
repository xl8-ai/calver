# calver

This action adds calver tag automatically to your current checkout branch

## Example usage

```yaml
on: [push]

jobs:
  add-tag:
    runs-on: ubuntu-latest

    name: Add a calver tag to current branch

    steps:
      - name: Checkout
        uses: actions/checkout@v3
        with:
          ref: staging # or main, master, etc..

      - name: Add a tag
        uses: xl8-web/calver@main
```
