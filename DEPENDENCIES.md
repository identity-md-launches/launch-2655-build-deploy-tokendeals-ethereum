# Vendored dependencies

All build and test dependencies are ordinary source files under `lib/`. No install, network, submodule, FFI or filesystem cheatcode access is needed.

openzeppelin-contracts v5.0.2
Source: https://codeload.github.com/OpenZeppelin/openzeppelin-contracts/tar.gz/refs/tags/v5.0.2
Archive SHA-256: 18c7b7e949b9a82dcd8cd394426c9c2636dfc263aa2317d4749dbfa0c7b3925a
Vendored files: 20

forge-std v1.9.7
Source: https://codeload.github.com/foundry-rs/forge-std/tar.gz/refs/tags/v1.9.7
Archive SHA-256: 45157353ab49eab01d294565866731e599b32401757229689ee459aa26b7ee94
Vendored files: 30

OpenZeppelin contains only the transitive source dependencies used by this project, including ERC20 for test mocks. Forge Standard Library contains its src tree. Upstream licenses are included alongside each dependency. Source files are unmodified.
