# tear.nvim

Frictionless note-taking for Neovim!

Using `lazy.nvim`:

```lua
{
  "tom-draper/tear.nvim",
  config = function()
    require("tear").setup({
      notes = {
        path = "~/notes/tear",  -- Where notes are saved
        extension = ".md",
        filename_strategy = "timestamp", -- or "content" to generate from first line
        datetime_format = "%Y-%m-%d-%H-%M-%S",
      },
    })
  end,
}
```

Using `packer.nvim`:

```lua
use {
  "tom-draper/tear.nvim",
  config = function()
    require("tear").setup({
      notes = {
        path = "~/notes/tear",
      },
    })
  end,
}
```

<p align="center"><b>"Tags are everything"</b></p>

Tear uses `#tags` within notes combined with content to automatically understand note relationships and structure.

**1. Create your first note:**

```
:Tear
```

For a single-line capture without leaving your current window:

```
:TearQuick This is a passing thought #inbox
```

**2. Type some content:**

```md
This is my first #book review

#book-review #books
```

File name and save location are already taken care of.

Just save with `:w`.

**3. View recent notes:**

```
:TearRecent
```

Recent notes include a short preview from the note body.
Press `<CR>` to open the latest note, or use `j`/`k` and arrow keys to choose another note.

**4. Search by tag:**

```
:TearSearch books
```

Search matches tags, keywords, previews, and note body text.

**5. Visualize notes:**

```
:TearVisualize
```
<br>
<p align="center">
  <img width="40" height="40" alt="image" src="https://github.com/user-attachments/assets/39d045d6-3455-4d70-a779-b0542974aed8" />
</p>
