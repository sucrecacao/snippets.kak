# Snippets paths
declare-option -hidden str snippets_plugin_path %sh(dirname "$kak_source")
declare-option -hidden str snippets_root_path %sh(dirname "$kak_opt_snippets_plugin_path")
declare-option -hidden str snippets_path "%opt{snippets_root_path}/snippets"

hook global ModuleLoaded snippets %{
  snippets-enable
}

provide-module snippets %{

  # Modules ────────────────────────────────────────────────────────────────────

  require-module prelude

  # Options ────────────────────────────────────────────────────────────────────

  # Snippets directories:
  # – ~/.config/kak/snippets
  # – /path/to/snippets.kak/snippets
  declare-option -docstring 'List of snippets directories' str-list snippets_directories "%val{config}/snippets" %opt{snippets_path}
  # Regex placeholder:
  # def {name}
  # 	{body}
  # end
  declare-option -docstring 'Regex to select snippet placeholders' str snippets_placeholder '\{[\w-]*\}'
  # Save registers
  declare-option -hidden str-list snippets_mark_register
  declare-option -hidden str-list snippets_search_register
  # Determines whether snippets are active
  declare-option -hidden bool snippets_active

  # Commands ───────────────────────────────────────────────────────────────────

  define-command snippets-enable -docstring 'Enable snippets' %{
    map global insert <a-ret> '<esc>: type-expand-command snippets-expand-selection<ret>' -docstring 'Expand the currently entered snippet (between a matching pair)'
  }

  define-command snippets-disable -docstring 'Disable snippets' %{
    unmap global insert <a-ret>
  }

  define-command snippets-expand-selection -docstring 'Expand selected snippet' %{
    snippets-replace "%reg{.}"
  }

  define-command snippets-list -docstring 'Visualize snippets in a scratch buffer' %{
    evaluate-commands %sh{
      . "$kak_opt_prelude"
      # Create a fifo
      state=$(mktemp -d)
      fifo=$state/fifo
      mkfifo "$fifo"
      {
        trap 'rm -Rf "$state"' EXIT
        {
          eval "set -- $kak_quoted_opt_snippets_directories"
          for directory do
            find -L "$directory/$kak_opt_filetype" "$directory/global" -type f |
            while read file; do
              if test -L "$file"; then
                # Symlink snippet
                real_path=$(readlink "$file")
                printf -- '--------------------------------------------------------------------------------\n'
                printf '%s → %s\n' "$file" "$real_path"
                printf -- '--------------------------------------------------------------------------------\n'
              else
                # Regular snippet
                printf -- '--------------------------------------------------------------------------------\n'
                printf '%s\n' "$file"
                printf -- '--------------------------------------------------------------------------------\n'
                # Read its content
                cat "$file"
              fi
            done
          done
        } > "$fifo"
      } < /dev/null > /dev/null 2>&1 &
      kak_escape edit! -fifo "$fifo" '*snippets*'
      kak_escape set-option buffer filetype "$kak_opt_filetype"
    }
  }

  alias global sl snippets-list

  # Implementation ─────────────────────────────────────────────────────────────

  define-command -hidden snippets-replace -params 1 %{
    snippets-paste 'R' %arg{1}
  }

  define-command -hidden snippets-insert -params 1 %{
    snippets-paste '<a-P>' %arg{1}
  }

  define-command -hidden snippets-append -params 1 %{
    snippets-paste '<a-p>' %arg{1}
  }

  define-command -hidden snippets-paste -params 2 %{
    evaluate-commands -save-regs '"' %{
      # Search the given snippet %arg{2} in snippets directories:
      # – <snippets-directories>/<filetype>/<name>
      # – <snippets-directories>/<filetype>/<subset>/<name>
      # – <snippets-directories>/global/<name>
      # – <snippets-directories>/global/<subset>/<name>
      evaluate-commands %sh{
        paste_method=$1
        snippet_name=$2
        eval "set -- $kak_quoted_opt_snippets_directories"
        for directory do
          set -- \
            "$directory/$kak_opt_filetype/$snippet_name" \
            "$directory/$kak_opt_filetype/"*"/$snippet_name" \
            "$directory/global/$snippet_name" \
            "$directory/global/"*"/$snippet_name"
          for snippet_path do
            if test -f "$snippet_path"; then
              printf 'set-register dquote %%file{%s}' "$snippet_path"
              exit
            fi
          done
        done
        # Abort if no snippet
        printf 'fail No such snippet: "%%opt{filetype}/%%arg{2}" "global/%%arg{2}" in %%opt{snippets_directories}'
      }
      # Paste using the specified method
      snippets-paste-text %arg{1} %reg{"}
    }
    # Once activated, snippets are active until all placeholders have been consumed.
    try %{
      evaluate-commands %sh{
        if test "$kak_opt_snippets_active" = true; then
          printf fail
        fi
      }
      set-option window snippets_active true
      # Save registers
      set-option window snippets_mark_register %reg{^}
      set-option window snippets_search_register %reg{/}
      # Save regions and set the search register for selecting placeholders
      execute-keys -save-regs '' Z
      set-register / %opt{snippets_placeholder}
      # Mappings for the whole insert session
      map window insert <a-n> '<a-;>: snippets-select-next-placeholder<ret>' -docstring 'Select the next placeholder'
      map window insert <a-p> '<a-;>: snippets-select-previous-placeholder<ret>' -docstring 'Select the previous placeholder'
      # Deactivate when no placeholder remains in saved regions.
      # Test when leaving insert mode.
      hook -group snippets-active window ModeChange pop:insert:normal %{
        try %{
          # Test if a placeholder matches in saved regions
          execute-keys -draft 'z<a-k><ret>'
        } catch %{
          # If not:
          # Restore registers
          set-register ^ %opt{snippets_mark_register}
          set-register / %opt{snippets_search_register}
          # Unmap
          unmap window insert <a-n>
          unmap window insert <a-p>
          # Deactivate
          unset-option window snippets_active
          remove-hooks window snippets-active
        }
      }
    }
    # Reduce selections to their cursor
    execute-keys ';'
  }

  define-command -hidden snippets-select-next-placeholder %{
    snippets-select-placeholder ')'
  }

  define-command -hidden snippets-select-previous-placeholder %{
    snippets-select-placeholder '<esc>'
  }

  # Belongs to the snippets-paste command.
  # The command is executed from a mapping in insert mode.
  # We reuse the mark and search registers set by snippets-paste.
  define-command -hidden snippets-select-placeholder -params 1 %{
    try %{
      # Test if saved regions contain a placeholder before modifying selections
      execute-keys -draft 'z<a-k><ret>'
      execute-keys '<a-;>z'
      evaluate-commands -itersel %{
        execute-keys "<a-;>s<ret><a-;>%arg{1}<a-;><space><a-;>d"
      }
    }
  }

  # Generics ───────────────────────────────────────────────────────────────────

  define-command -hidden snippets-replace-text -params 1 %{
    snippets-paste 'R' %arg{1}
  }

  define-command -hidden snippets-insert-text -params 1 %{
    snippets-paste '<a-P>' %arg{1}
  }

  define-command -hidden snippets-append-text -params 1 %{
    snippets-paste '<a-p>' %arg{1}
  }

  define-command -hidden snippets-paste-text -params 2 %{
    evaluate-commands -save-regs '"' %{
      # Paste using the specified method
      # The command (R, <a-P> and <a-p>) selects inserted text
      set-register '"' %arg{2}
      execute-keys %arg{1}
      # Remove EOF newline
      execute-keys 'a<backspace><esc>'
      # Replace leading tabs with the appropriate indent
      try %{
        evaluate-commands %sh{
          if test "$kak_opt_indentwidth" -eq 0; then
            printf fail
          fi
        }
        execute-keys -draft "<a-s>s\A\t+<ret>s.<ret>%opt{indentwidth}@"
      }
      # Align everything with the current line
      evaluate-commands -draft -itersel %{
        try %{
          execute-keys '<a-s>Z)<space><a-x>s^\h+<ret>yz)<a-space>_P'
        }
      }
    }
  }
}

require-module snippets
