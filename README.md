# docker.nvim

A modern Docker plugin for Neovim with floating window interface.

## Features

- **Floating Window UI**: Clean, modern interface using Neovim's floating windows
- **Container Management**: Start, stop, restart, and remove containers
- **Image Management**: List, pull, and run Docker images
- **No External Dependencies**: Uses curl for Docker API communication
- **Customizable Keymaps**: Flexible key mapping system using `<Plug>` mappings

## Requirements

- Neovim >= 0.8.0
- Docker daemon running
- `curl` command available

## Installation

### Using [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
  'skanehira/docker.nvim',
  opts = {
    -- Configuration options (optional)
  }
}
```

### Using [packer.nvim](https://github.com/wbthomason/packer.nvim)

```lua
use {
  'skanehira/docker.nvim',
  config = function()
    require('docker').setup({
      -- Configuration options (optional)
    })
  end
}
```

## Usage

### Commands

- `:DockerContainers` - Show containers in floating window
- `:DockerImages` - Show images in floating window

### Default Keymaps

```lua
-- Global keymaps
vim.keymap.set('n', '<leader>dc', ':DockerContainers<CR>')
vim.keymap.set('n', '<leader>di', ':DockerImages<CR>')
```

### Container Window Keymaps

- `u` - Start container
- `d` - Stop container
- `r` - Restart container
- `x` - Remove container
- `l` - Show logs
- `e` - Execute shell
- `q` - Quit window

### Image Window Keymaps

- `<CR>` - Run image
- `x` - Remove image
- `p` - Pull image
- `i` - Inspect image
- `q` - Quit window

## Configuration

```lua
require('docker').setup({
  -- Window settings
  window = {
    width = 0.8,   -- 80% of screen width
    height = 0.8,  -- 80% of screen height
    border = 'rounded', -- Border style
  },
  
  -- Docker settings
  docker = {
    socket_path = '/var/run/docker.sock',
    timeout = 5000, -- Request timeout in milliseconds
  },
  
  -- Custom keymaps
  keymaps = {
    containers = {
      start = 'u',
      stop = 'd',
      restart = 'r',
      remove = 'x',
      logs = 'l',
      exec = 'e',
      quit = 'q',
    },
    images = {
      run = '<CR>',
      remove = 'x',
      pull = 'p',
      inspect = 'i',
      quit = 'q',
    }
  }
})
```

## Custom Keymaps

You can customize keymaps using `<Plug>` mappings:

```lua
-- Container window keymaps
vim.keymap.set('n', 's', '<Plug>(docker-container-start)', { buffer = true })
vim.keymap.set('n', 'k', '<Plug>(docker-container-stop)', { buffer = true })

-- Image window keymaps  
vim.keymap.set('n', 'r', '<Plug>(docker-image-run)', { buffer = true })
vim.keymap.set('n', 'd', '<Plug>(docker-image-remove)', { buffer = true })
```

## Development

### Testing

```bash
# Run all tests
make test

# Run specific test file
nvim -l tests/docker/api_spec.lua
```

### TDD Workflow

This project follows Test-Driven Development (TDD):

1. **Red**: Write failing test
2. **Green**: Write minimal code to pass test
3. **Refactor**: Improve code while keeping tests passing

## Architecture

```
lua/docker/
├── init.lua           -- Main API
├── config.lua         -- Configuration management
├── api.lua            -- Docker API client
├── ui.lua             -- Floating window management
├── actions.lua        -- User action handlers
└── mappings.lua       -- Keymap definitions
```

## License

MIT

## Related Projects

- [denops-docker.vim](https://github.com/skanehira/denops-docker.vim) - Vim/Neovim Docker plugin using Denops