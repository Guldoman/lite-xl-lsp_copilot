# Copilot for Lite XL

This is a messy initial implementation of Copilot using the LSP server from
[copilot.vim](https://github.com/github/copilot.vim).

## Installation

Using [lpm](https://github.com/lite-xl/lite-xl-plugin-manager):
```
lpm add https://github.com/Guldoman/lite-xl-lsp_copilot:master
lpm install lsp_copilot
```

## Usage

The first time Copilot is executed you'll have to login by calling the
`Copilot: Sign In` command from the command palette.
You'll be given an URL and a code to connect to your Github account.
After logging in, wait a few seconds and you'll get a message in the Lite XL
status bar about successfully logging in. You can now use Copilot.

At the moment, every time you type or move the caret, Copilot will be
interrogated for completions.
Completions from other LSP servers and the default word suggestions
take priority.

You can use the command `Copilot: Get Completions` to manually ask Copilot for
suggestions.

The command `Copilot: Get Panel Completions` can be used to ask Copilot for
multiple suggestions at once.
A new panel will be split on the right, and you'll be able to interact with the
proposed code blocks to copy-paste the code.
The command `Copilot: Accept Panel Solution` can be used to apply a solution
while its code block is focused.

The command `Copilot: Sign Out` can be used to log out from Copilot.

## TODO

- [ ] Allow temporarily disabling Copilot
- [ ] Allow temporarily disabling Copilot from certain files
- [ ] Allow disabling Copilot from certain file formats
- [ ] Allow disabling Copilot suggestions while typing, allowing only manually
      triggered ones
- [ ] Implement ghost text
- [ ] Implement Copilot chat
