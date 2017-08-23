---
title: Stackage to Nix
author: Dmitry @4e6 Bushev
---

# Stackage to Nix

[stackage2nix][stackage2nix] is a tool that generates Nix build instructions
from Stack file. Just like `cabal2nix` but for Stack.

Here I would like to tell you a story of its creation, show some usage examples,
and finally talk about problems solved.

## The story of one build

In Typeable we use Stack for development. It solves a bunch of problems you face
during a development of the large Haskell projects. But the main benefit you get
is of course Stackage.

For the production builds we use Nix. It has some nice properties like
declarative build configuration, reproducible builds, etc. If you for some
reason was not aware of it, I encourage you to give it a try. Nixpkgs differs
from other build tools in a variety of ways. I'd call its approach developers
friendly. It may take some time to get into, but it's worth it.

So, we got Stack on one side and Nix on the other. The question is, how would
you build the Stack project with Nix?

Our first approach was defining Nix derivation using Stack as a builder. Nixpkgs
already has [haskell.lib.buildStackProject][nixpkgs-stack] helper function
defined for it. Unfortunately, this method has several downsides. The main one
is that Nix does not have control over the Stack cache. In fact, we end up with
the builds that fail quite frequently and require manual interventions. Usually,
all the problems can be resolved by dropping the Stack cache, followed by the
painfully slow compilation of a project from scratch.

The more _native_ way to build Haskell in Nix is to describe each Haskell
package as a separate Nix package. This way we get the caching property and all
Nix benefits out of the box. Nixpkgs repository already maintains some version
of the Hackage snapshot predefined, but we need packages of particular versions
from Stackage. So the logical outcome would be to create Stackage snapshot for
Nixpkgs.

At that time, there already was a discussion of such thing on cabal2nix [issue
#212][cabal2nix-issue-stack], where Benno @bennofs mentioned his WIP
implementation.

The second approach was to create an override for Nixpkgs manually using
existing tool. With Stackage packages set instead of default Hackage snapshot,
and with additional overrides from `stack.yaml`. This solution worked better
than the first one with bare Stack. The downside was that we got some extra Nix
code to maintain in our project.

After the creation of manual Nixpkgs override, it became apparent that the
procedure could be automated. We just need to parse `stack.yaml` build
definition, generate Nix Stackage packages set for particular LTS snapshot, and
then apply the overrides from Stack file on top of it. Sounds manageable.

So, the third approach was to build the tool that would generate Nixpkgs
override given the Stack build definition. That's how we get to `stackage2nix`.

## Example Usage

In the current implementation, `stackage2nix` has three required arguments.

``` bash
stackage2nix \
  --lts-haskell "$LTS_HASKELL_REPO" \
  --all-cabal-hashes "$ALL_CABAL_HASHES_REPO" \
  ./stack.yaml
```

- `--lts-haskell` path to [fpco/lts-haskell][lts-haskell] repository
- `--all-cabal-hashes` path to
  [coommercialhaskell/all-cabal-hashes][all-cabal-hashes] repository checked out
  to `hackage` branch
- path to `stack.yaml` file or directory containing it

Produced Nix derivation split into the following files:

- packages.nix - Base Stackage packages set
- configuration-packages.nix - Compiler configuration
- default.nix - Final Haskell packages set with all overrides applied

The result Haskell packages set defined the same way as in Nixpkgs:

``` nix
callPackage <nixpkgs/pkgs/development/haskell-modules> {
  ghc = pkgs.haskell.compiler.ghc7103;
  compilerConfig = self: extends pkgOverrides (extends stackageConfig (stackagePackages self));
}
```

That means you can apply the same overrides as for default Haskell packages in
Nixpkgs. As an example, the following snippet shows an example of release
derivation `release.nix`. It compiles all packages with `-O2` GHC flag and
enables static linking for `stackage2nix` executable.

``` nix
with import <nixpkgs> {};
with pkgs.haskell.lib;
let haskellPackages = import ./. {};
in haskellPackages.override {
  overrides = self: super: {
    mkDerivation = args: super.mkDerivation (args // {
      configureFlags = (args.configureFlags or []) ++ ["--ghc-option=-O2"];
    });

    stackage2nix = disableSharedExecutables super.stackage2nix;
  };
}
```

``` bash
nix-build -A stackage2nix override.nix
```

For other examples you can check
[4e6/stackage2nix-examples][stackage2nix-examples] repository. I created it
during development, as a sandbox to verify `stackage2nix` by running it on
different OSS projects.

## How it works

Apparently, assembling things from parts is hard. And it's not an exception in
Haskell. In this final section, I'll explain what `stackage2nix` does to produce
the correct Nix build.

As a small step aside, I like to think about `stackage2nix` as a function that
translates Stack build definition to Nix in an idempotent way. Once again, the
inputs are:

- [fpco/lts-haskell][lts-haskell] repository with Stackage LTS snapshots.
- [coommercialhaskell/all-cabal-hashes][all-cabal-hashes] repository containing
  information about packages from Hackage.
- Stack build definition `stack.yaml.`

Now, we got the inputs. First things first, parse `stack.yaml` file to obtain
the configuration of the current build. And load appropriate LTS Stackage
packages set from `fpco/lts-haskell`.

And here's the first challenge. Every package on Hackage for a single version
can have several revisions. Like here, [mtl-2.2.1][mtl-revisions] has two
variants with different constraints on the dependencies. That said, we would
like to get the exact revision of the package that was used in Stackage LTS
because otherwise, in the worst case we might not be able to resolve the correct
dependencies, and the final build may not work.  Luckily, LTS metadata contains
the SHA1 hash of the package in `commercialhaskell/all-cabal-hashes` repo. So
far so good.

So first we try to load package by hash. But in reality that might be the case
that SHA1 hash is missing, or repository doesn't contain an object with this
hash.  Then fall back and try to load the latest revision of the package from
`commercialhaskell/all-cabal-hashes` repo. But this could also fail because
apparently, some files can be incomplete and missing its accompanying
metadata. The real world is a rough place.  Finally, try to load the package
from local Cabal database. The tool uses either the default one in `~/.cabal`
directory, or can be overridden by `--hackage-db` flag.

Okay cool, we've loaded the packages. But then we got another problem. Stackage
LTS packages set `fpco/lts-haskell` is a list of packages with their
dependencies. It forms a graph with packages as vertices and dependencies as
edges. The problem is this that this graph might have cycles, and when it does,
Nix fails when tries to resolve target dependencies. Usually, cycles are caused
by test dependencies, and we can break them by removing test dependencies from
problematic packages. As a result in `configuration-packages.nix` you can see
something like:

``` nix
# break cycle: statistics monad-par mwc-random vector-algorithms
"mwc-random" = dontCheck super.mwc-random;
```

Okay, now we've got Stackage LTS packages for Nix. The final step is to apply
package overrides from `stack.yaml` file. Remember the _revisions_ thing? Right,
the new packages were never tested with the LTS snapshot. They add new
constraints into the play that may break the integrity of Stackage LTS
packages. The best thing we could do here is to bump revisions for their
dependencies and rely on the fact that Stack solver checked them when the
project was compiled with Stack tool.

So apparently, building Haskell is not quite trivial as it first seems. And
`stackage2nix` makes its best attempt to construct something buildable.

The project is not on Hackage yet. Regarding the further development plans, I
would like to focus on usability first, and eventually, when project matures,
we'll make it to the Hackage.

[nixpkgs-stack]: https://nixos.org/nixpkgs/manual/#how-to-build-a-haskell-project-using-stack
[cabal2nix-issue-stack]: https://github.com/NixOS/cabal2nix/issues/212
[stackage2nix]: https://github.com/4e6/stackage2nix
[lts-haskell]: https://github.com/fpco/lts-haskell
[all-cabal-hashes]: https://github.com/commercialhaskell/all-cabal-hashes
[mtl-revisions]: https://hackage.haskell.org/package/mtl-2.2.1/revisions/
