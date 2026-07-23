" tachydromos.nvim: minimal regex-based syntax highlighting for .http files.
"
" This is a deliberate fallback, not a Tree-sitter grammar: there is no
" widely-available, well-maintained `http` Tree-sitter parser shipped by
" nvim-treesitter as of this writing. If/when one exists, prefer adding
" `queries/http/highlights.scm` and letting `:TSInstall http` take over
" instead of extending this file further.

if exists('b:current_syntax')
  finish
endif

syntax case match

" ### NAME request separators
syntax match httpRequestName /^###.*$/

" HTTP methods starting a request line (GRAPHQL is a tachy-supported shaped POST)
syntax match httpMethod /^\(GET\|POST\|PUT\|PATCH\|DELETE\|HEAD\|OPTIONS\|GRAPHQL\)\>/

" Comments
syntax match httpComment /^\s*#.*$/
syntax match httpComment "^\s*//.*$"

" @name = value file-header / block-preamble declarations
syntax match httpVariableDecl /^@[A-Za-z_][A-Za-z0-9_-]*\s*=/

" Other @directives without `=` (e.g. @expect-status-code, @timeout, @no-cookie-jar)
syntax match httpDirective /^@[A-Za-z][A-Za-z0-9_-]*\>/

" {{var}} / {{$magic}} placeholders
syntax match httpPlaceholder /{{[^}]*}}/

" >>/>>! save-response-to-file directives
syntax match httpSaveDirective /^>>!\?.*$/

" URLs
syntax match httpUrl "\<\(https\?\|wss\?\):\/\/\S*"

" `Name: value` header lines
syntax match httpHeaderName /^[A-Za-z][A-Za-z0-9-]*:/he=e-1

highlight default link httpRequestName Title
highlight default link httpMethod Keyword
highlight default link httpComment Comment
highlight default link httpVariableDecl Identifier
highlight default link httpDirective PreProc
highlight default link httpPlaceholder Special
highlight default link httpSaveDirective PreProc
highlight default link httpUrl Underlined
highlight default link httpHeaderName Type

let b:current_syntax = 'http'
