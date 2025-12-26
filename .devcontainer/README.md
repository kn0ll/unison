# Unison Development Container

This devcontainer provides a complete development environment for the Unison programming language codebase.

## Features

- **GHCup-managed tooling**: GHC, Stack, Cabal, and HLS installed via GHCup
- **GHC 9.6.5**: Matching the project's LTS 22.26 resolver
- **VS Code Extensions**: Haskell language support pre-installed

## Getting Started

1. **Open in VS Code** with the Dev Containers extension installed
2. **Reopen in Container** when prompted (or use Command Palette → "Dev Containers: Reopen in Container")
3. **Wait for setup** - the first run will install GHC and the Haskell toolchain

## Usage

Once inside the container:

```bash
# Build the project
stack build

# Run tests
stack test --fast

# Run the Unison CLI
stack exec unison
```

### Using Cabal

You can also use Cabal instead of Stack:

```bash
# Build with Cabal
cabal build --project-file=contrib/cabal.project all

# Run tests
cabal test --project-file=contrib/cabal.project all
```

## Tooling Versions

- GHC: 9.6.5 (from LTS 22.26)
- Stack: 2.15.7
- Cabal: 3.10.3.0
- HLS: Latest compatible version

## Alternative: Nix-based Development

If you prefer to use Nix (which provides exact version matching), you can install Nix inside the container:

```bash
# Install Nix
sh <(curl -L https://nixos.org/nix/install) --daemon

# Configure Unison's cache
mkdir -p ~/.config/nix
echo 'experimental-features = nix-command flakes
extra-trusted-public-keys = unison.cachix.org-1:i1DUFkisRPVOyLp/vblDsbsObmyCviq/zs6eRuzth3k=
extra-trusted-substituters = https://unison.cachix.org' > ~/.config/nix/nix.conf

# Enter the dev shell
nix develop --accept-flake-config
```

## Troubleshooting

### HLS not working?

Restart the Haskell Language Server from VS Code Command Palette: "Haskell: Restart Haskell LSP Server"

### Build errors?

Make sure you're using the correct GHC version:

```bash
ghcup set ghc 9.6.5
```

## More Information

- See [`development.markdown`](../development.markdown) for detailed development instructions
- See [`nix/README.md`](../nix/README.md) for Nix-specific documentation
