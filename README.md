# docker.nvim

A Neovim plugin to operate Docker. On top of containers, images, volumes and networks, it **lists and operates the services of every docker compose project at once**. Whichever directory Neovim is opened in, all the compose projects on the machine (both `shop` and `blog` when you started them separately) appear in a single list.

```
NAME                     PROJECT  SERVICE  IMAGE         STATUS         PORTS
shop-web-1               shop     web      nginx:alpine  Up 5 days      0.0.0.0:8080->80/tcp
shop-db-1                shop     db       postgres:16   Up 5 days
my-standalone-container                    alpine:3.20   Exited (0) 3h
```

## Requirements

- Neovim 0.10 or later (uses `vim.system`)
- The `docker` command on PATH
- `:Docker services` needs the `docker compose` subcommand
- Supported platforms are macOS and Linux

There are no runtime plugin dependencies. [plenary.nvim](https://github.com/nvim-lua/plenary.nvim) is used only to run the tests.

## Installation

[lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "skanehira/docker.nvim",
  cmd = "Docker",
  opts = {},
}
```

Passing `opts` calls `require("docker").setup(opts)`. `opts = {}` is enough when you keep the defaults. For replacing keymaps and highlights, see `:help docker-configuration`.

## Features

| Command              | Description                                  |
| -------------------- | -------------------------------------------- |
| `:Docker containers` | container list                               |
| `:Docker images`     | image list                                   |
| `:Docker volumes`    | volume list                                  |
| `:Docker networks`   | network list                                 |
| `:Docker services`   | compose service list (all projects combined) |

Lists open in a float window, and keys are set only in that buffer. What each view can do:

- **Containers**: start / stop / restart / kill / pause / delete, follow logs, open a shell, run a command, edit a file inside the container, copy files to and from the host, open a published port in the browser
- **Images**: shell in a throwaway container / delete / go to the containers using the image
- **Volumes and networks**: delete
- **compose services**: start / stop / restart / logs per service, start / remove per project, go to the containers of the service
- **Every view**: show the details (`docker inspect`), filter with `<C-f>`, switch views with `<Tab>`, list the keys with `?`, delete a Visual mode selection at once (except the compose service list)

Lists subscribe to `docker events` and refresh themselves. When you start or stop a container from another terminal, the list in Neovim catches up within a second.

Mappings such as `<Plug>(docker-containers)` are exposed as well, so you can bind them to any key.

```lua
vim.keymap.set("n", "<leader>dc", "<Plug>(docker-containers)")
```

## Documentation

The full keymap list, the configuration options and the behavior this plugin promises (deletion never passes `-f`, how the target of a compose operation is decided, and so on) live in the Neovim help.

```vim
:help docker.nvim
```

| Section                      | Contents                                         |
| ---------------------------- | ------------------------------------------------ |
| `:help docker-commands`      | commands, Lua API and `<Plug>` mappings          |
| `:help docker-keymaps`       | keymaps per view                                 |
| `:help docker-configuration` | `setup()` options and highlights                 |
| `:help docker-behavior`      | promised behavior (deletion, exclusion, compose) |

## Development

```bash
make check     # lint / format-check / typecheck / plugin-check / spec-layout-check / test
make test      # unit and integration tests
make test-e2e  # end-to-end scenarios against a real docker (docker required)
```

`make test-file FILE=path/to/foo_spec.lua` runs a single file.

## License

MIT
