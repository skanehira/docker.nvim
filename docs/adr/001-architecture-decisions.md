# ADR-001: docker.nvim Architecture Decision Record

## Status
Approved

## Background & Context

Developing a new Neovim-specific Docker plugin based on the existing denops-docker.vim plugin. While denops-docker.vim is implemented in TypeScript/Deno using the denops.vim framework, it has the following limitations:

- Performance issues due to denops startup overhead
- Unable to leverage Neovim-specific features due to Vim/Neovim dual compatibility
- Complexity of the virtual buffer system

## Decisions

### 1. Technology Stack
**Decision**: Lua native implementation + Neovim floating windows
- **Rationale**: 
  - Significant reduction in startup time (no denops startup required)
  - Maximum utilization of Neovim-specific features
  - Improved maintainability (simpler than TypeScript)

### 2. UI Design
**Decision**: Floating window only, no virtual buffers
- **Rationale**:
  - Modern and intuitive UI
  - Does not pollute existing buffers
  - Interactive operability
- **Alternative**: Virtual buffers (`docker://` scheme) were deemed too complex

### 3. Operation Flow
**Decision**: Simple design centered on list views, no detail screens needed
- **Rationale**:
  - Improved development efficiency
  - Enhanced usability (no screen transitions)
  - Better maintainability
- **Alternative**: Detail screens are reserved for future extensions

### 4. Docker API Communication
**Decision**: Use curl for now, direct Unix domain socket communication in the future
- **Rationale**:
  - Prioritize development speed
  - curl has high stability and compatibility
  - Future implementation with libuv to eliminate external dependencies
- **Alternative**: Custom implementation from the start would have high development costs

### 5. Key Mapping Design
**Decision**: Customizable key bindings via `<Plug>` mappings
- **Rationale**:
  - Avoid conflicts with users' existing keymaps
  - Flexible customization
  - Standard Vim plugin pattern

## Architecture Overview

```
┌─────────────────────────────────────────┐
│     Neovim Commands & Keymaps           │
│  :DockerContainers, <Plug> mappings     │
└────────────────┬────────────────────────┘
                 │
┌────────────────┴────────────────────────┐
│     Floating Window Manager             │
│  - Window Creation/Management           │
│  - Buffer Content Rendering             │
│  - Interactive Key Handling             │
└────────────────┬────────────────────────┘
                 │
┌────────────────┴────────────────────────┐
│        UI Components                    │
│  - Table Rendering                      │
│  - Status Indicators                    │
│  - Key Help Display                     │
└────────────────┬────────────────────────┘
                 │
┌────────────────┴────────────────────────┐
│       Docker API Client                 │
│  - curl-based HTTP Communication        │
│  - Response Processing                  │
│  - Error Handling                       │
└─────────────────────────────────────────┘
```

## MVP Specification

### Target Features
1. **Container List Display**
   - Table display in floating window
   - Same display items as denops-docker.vim
   - Real-time status updates

2. **Basic Operations**
   - Start container (u key)
   - Stop container (d key)
   - Close window (q key)

3. **Display Items**
   - Container name
   - Image name
   - Status (● indicates running)
   - Port information
   - Creation time

### File Structure
```
lua/docker/
├── init.lua           -- Main API
├── config.lua         -- Configuration management  
├── api.lua            -- Docker API communication (curl)
├── ui.lua             -- Floating window management
├── actions.lua        -- Operation handlers
└── mappings.lua       -- Keymap definitions
```

## Impact & Trade-offs

### Benefits
- **Performance**: Significant improvement in startup time
- **Usability**: Modern floating window UI
- **Extensibility**: Easy customization with Lua API
- **Maintainability**: Simple design

### Drawbacks & Constraints
- **External dependency**: curl dependency (to be resolved in future)
- **Feature limitation**: Minimal features in MVP only
- **Neovim only**: No Vim support

## Future Extension Plans

### Phase 2 and beyond
- Image management features
- Network management features
- Log viewer
- Metrics display

### Technical Improvements
- Direct Unix domain socket communication
- Async processing optimization
- Enhanced error handling

## References
- [denops-docker.vim](https://github.com/skanehira/denops-docker.vim) - Existing implementation
- [Neovim Lua Guide](https://neovim.io/doc/user/lua-guide.html)
- [Docker Engine API](https://docs.docker.com/engine/api/)