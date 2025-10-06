# tear.nvim

Frictionless note-taking for Neovim!

Using `lazy.nvim`:

```lua
{
  "tom-draper/tear.nvim",
  config = function()
    require("tear").setup({
      notes_path = "~/notes/tear",  -- Where notes are saved
      naming_strategy = "timestamp", -- or "content" to generate from first line
      datetime_format = "%Y-%m-%d-%H-%M-%S",
      file_extension = ".md",
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
      notes_path = "~/notes/tear",
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

**2. Type some content:**

```md
This is my first #book review

#book-review #books
```

File name and save location is already taken care of.

Just save with `:w`.

**3. View recent notes:**

```
:TearRecent
```

**4. Search by tag:**

```
:TearSearch books
```

**5. Visualize notes:**

```
:TearVisualize
```
