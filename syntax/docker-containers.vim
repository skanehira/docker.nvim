" Syntax highlighting for docker containers

" Define highlight groups
hi! DockerContainerHeader ctermfg=216 guifg=#e2a478 cterm=bold gui=bold
hi! DockerContainerUp ctermfg=107 guifg=#a0c980
hi! DockerContainerRunning ctermfg=107 guifg=#a0c980
hi! DockerContainerExitedError cterm=bold ctermfg=203 gui=bold guifg=#ec7279
hi! DockerContainerExited ctermfg=243 guifg=#7c7c7c
hi! DockerContainerPaused ctermfg=178 guifg=#dab997
hi! DockerContainerRestarting ctermfg=178 guifg=#dab997

" Match patterns for different container states
syntax match DockerContainerHeader /^  ID.*/

" Match only the running indicator (●) based on container state
syntax match DockerContainerUp /^●/ contained nextgroup=DockerContainerUpLine
syntax match DockerContainerRunning /^●/ contained nextgroup=DockerContainerRunningLine
syntax match DockerContainerRestarting /^●/ contained nextgroup=DockerContainerRestartingLine

" Match the full line to apply the contained highlighting
syntax match DockerContainerUpLine /^● .* Up .*/ contains=DockerContainerUp
syntax match DockerContainerRunningLine /^● .* running .*/ contains=DockerContainerRunning
syntax match DockerContainerRestartingLine /^● .* restarting .*/ contains=DockerContainerRestarting

" Set filetype
let b:current_syntax = "docker-containers"