export build_tarballs, autobuild, print_buildjl, product_hashes_from_github_release
import GitHub: gh_get_json, DEFAULT_API
import SHA: sha256

"""
    build_tarballs(ARGS, src_name, sources, script, platforms, products,
                   dependencies)

This should be the top-level function called from a `build_tarballs.jl` file.
It takes in the information baked into a `build_tarballs.jl` file such as the
`sources` to download, the `products` to build, etc... and will automatically
download, build and package the tarballs, generating a `build.jl` file when
appropriate.  Note that `ARGS` should be the top-level Julia `ARGS` command-
line arguments object.  This function does some rudimentary parsing of the
`ARGS`, call it with `--help` in the `ARGS` to see what it can do.
"""
function build_tarballs(ARGS, src_name, sources, script, platforms, products,
                        dependencies)
    # See if someone has passed in `--help`, and if so, give them the
    # assistance they so clearly long for
    if "--help" in ARGS
        println(strip("""
        Usage: build_tarballs.jl [target1,target2,...] [--only-buildjl]
                                 [--verbose] [--help]

        Options:
            targets         By default `build_tarballs.jl` will build a tarball
                            for every target within the `platforms` variable.
                            To override this, pass in a list of comma-separated
                            target triplets for each target to be built.  Note
                            that this can be used to build for platforms that
                            are not listed in the 'default list' of platforms
                            in the build_tarballs.jl script.

            --verbose       This streams compiler output to stdout during the
                            build which can be very helpful for finding bugs.
                            Note that it is colorized if you pass the
                            --color=yes option to julia, see examples below.

            --only-buildjl  This disables building of any tarballs, and merely
                            reconstructs a `build.jl` file from a github
                            release.  This is mostly useful as a later stage in
                            a travis/github releases autodeployment setup.

            --help          Print out this message.

        Examples:
            julia --color=yes build_tarballs.jl --verbose
                This builds all tarballs, with colorized output.

            julia build_tarballs.jl x86_64-linux-gnu,i686-linux-gnu
                This builds two tarballs for the two platforms given, with a
                minimum of output messages.
        """))
        return nothing
    end

    # This sets whether we should build verbosely or not
    verbose = "--verbose" in ARGS
    ARGS = filter!(x -> x != "--verbose", ARGS)

    # This flag skips actually building and instead attempts to reconstruct a
    # build.jl from a GitHub release page.  Use this to automatically deploy a
    # build.jl file even when sharding targets across multiple CI builds.
    only_buildjl = "--only-buildjl" in ARGS
    ARGS = filter!(x -> x != "--only-buildjl", ARGS)

    # If we're only reconstructing a build.jl file, we _need_ this information
    # otherwise it's useless, so go ahead and error() out here.
    if only_buildjl && (!all(haskey.(ENV, ["TRAVIS_REPO_SLUG", "TRAVIS_TAG"])))
        msg = strip("""
        Must provide repository name and tag through Travis-style environment
        variables like TRAVIS_REPO_SLUG and TRAVIS_TAG!
        """)
        error(replace(msg, "\n" => " "))
    end

    # If the user passed in a platform (or a few, comma-separated) on the
    # command-line, use that instead of our default platforms
    should_override_platforms = length(ARGS) > 0
    if should_override_platforms
        platforms = platform_key.(split(ARGS[1], ","))
    end

    # If we're running on Travis and this is a tagged release, automatically
    # determine bin_path by building up a URL, otherwise use a default value.
    # The default value allows local builds to not error out
    bin_path = "https:://<path to hosted binaries>"
    if !isempty(get(ENV, "TRAVIS_TAG", ""))
        repo_name = ENV["TRAVIS_REPO_SLUG"]
        tag_name = ENV["TRAVIS_TAG"]
        bin_path = "https://github.com/$(repo_name)/releases/download/$(tag_name)"
    end

    product_hashes = if !only_buildjl
        # If the user didn't just ask for a `build.jl`, go ahead and actually build
        Compat.@info("Building for $(join(triplet.(platforms), ", "))")

        # Build the given platforms using the given sources
        autobuild(pwd(), src_name, platforms, sources, script,
                         products, dependencies; verbose=verbose)
    else
        msg = strip("""
        Reconstructing product hashes from GitHub Release $(repo_name)/$(tag_name)
        """)
        Compat.@info(msg)

        # Reconstruct product_hashes from github
        product_hashes_from_github_release(repo_name, tag_name; verbose=verbose)
    end

    # If we didn't override the default set of platforms OR we asked for only
    # a build.jl file, then write one out.  We don't write out when overriding
    # the default set of platforms because that is typically done either while
    # testing, or when we have sharded our tarball construction over multiple
    # invocations.
    if !should_override_platforms || only_buildjl
        dummy_prefix = Prefix(pwd())
        print_buildjl(pwd(), products(dummy_prefix), product_hashes, bin_path)

        if verbose
            Compat.@info("Writing out the following reconstructed build.jl:")
            print_buildjl(STDOUT, products(dummy_prefix), product_hashes, bin_path)
        end
    end

    return product_hashes
end


"""
    autobuild(dir::AbstractString, src_name::AbstractString, platforms::Vector,
              sources::Vector, script::AbstractString, products::Function,
              dependencies::Vector; verbose::Bool = true)

Runs the boiler plate code to download, build, and package a source package
for a list of platforms.  `src_name` represents the name of the source package
being built (and will set the name of the built tarballs), `platforms` is a
list of platforms to build for, `sources` is a list of tuples giving
`(url, hash)` of all sources to download and unpack before building begins,
`script` is a string representing a `bash` script to run to build the desired
products, which are listed as `Product` objects within the vector returned by
the `products` function. `dependencies` gives a list of dependencies that
provide `build.jl` files that should be installed before building begins to
allow this build process to depend on the results of another build process.
"""
function autobuild(dir::AbstractString, src_name::AbstractString,
                   platforms::Vector, sources::Vector,
                   script::AbstractString, products::Function,
                   dependencies::Vector = AbstractDependency[];
                   verbose::Bool = true)
    # If we're on Travis and we're not verbose, schedule a task to output a "." every few seconds
    if haskey(ENV, "TRAVIS") && !verbose
        run_travis_busytask = true
        travis_busytask = @async begin
            # Don't let Travis think we're asleep...
            Compat.@info("Brewing a pot of coffee for Travis...")
            while run_travis_busytask
                sleep(4)
                print(".")
            end
        end
    end

    # This is what we'll eventually return
    product_hashes = Dict()

    # If we end up packaging any local directories into tarballs, we'll store them here
    mktempdir() do tempdir
        # First, download the source(s), store in ./downloads/
        downloads_dir = joinpath(dir, "downloads")
        try mkpath(downloads_dir) end

        # We must prepare our sources.  Download them, hash them, etc...
        sources = Any[s for s in sources]
        for idx in 1:length(sources)
            # If the given source is a local path that is a directory, package it up and insert it into our sources
            if typeof(sources[idx]) <: AbstractString
                if !isdir(sources[idx])
                    error("Sources must either be a pair (url => hash) or a local directory")
                end

                # Package up this directory and calculate its hash
                tarball_path = joinpath(tempdir, basename(sources[idx]) * ".tar.gz")
                package(sources[idx], tarball_path; verbose=verbose)
                tarball_hash = open(tarball_path, "r") do f
                    bytes2hex(sha256(f))
                end

                # Now that it's packaged, store this into sources[idx]
                sources[idx] = (tarball_path => tarball_hash)
            elseif typeof(sources[idx]) <: Pair
                src_url, src_hash = sources[idx]

                # If it's a .git url, clone it
                if endswith(src_url, ".git")
                    src_path = joinpath(downloads_dir, basename(src_url))
                    if !isdir(src_path)
                        repo = LibGit2.clone(src_url, src_path; isbare=true)
                    else
                        LibGit2.with(LibGit2.GitRepo(src_path)) do repo
                            LibGit2.fetch(repo)
                        end
                    end
                else
                    if isfile(src_url)
                        # Immediately abspath() a src_url so we don't lose track of
                        # sources given to us with a relative path
                        src_path = abspath(src_url)

                        # And if this is a locally-sourced tarball, just verify
                        verify(src_path, src_hash; verbose=verbose)
                    else
                        # Otherwise, download and verify
                        src_path = joinpath(downloads_dir, basename(src_url))
                        download_verify(src_url, src_hash, src_path; verbose=verbose)
                    end
                end

                # Now that it's downloaded, store this into sources[idx]
                sources[idx] = (src_path => src_hash)
            else
                error("Sources must be either a `URL => hash` pair, or a path to a local directory")
            end
        end

        # Our build products will go into ./products
        out_path = joinpath(dir, "products")
        try mkpath(out_path) end

        for platform in platforms
            target = triplet(platform)

            # We build in a platform-specific directory
            build_path = joinpath(pwd(), "build", target)
            try mkpath(build_path) end

            cd(build_path) do
                src_paths, src_hashes = collect(zip(sources...))

                # Convert from tuples to arrays, if need be
                src_paths = collect(src_paths)
                src_hashes = collect(src_hashes)
                prefix, ur = setup_workspace(build_path, src_paths, src_hashes, dependencies, platform; verbose=verbose)

                # Don't keep the downloads directory around
                rm(joinpath(prefix, "downloads"); force=true, recursive=true)

                dep = Dependency(src_name, products(prefix), script, platform, prefix)
                if !build(ur, dep; verbose=verbose, autofix=true)
                    error("Failed to build $(target)")
                end

                # Remove the files of any dependencies
                for dependency in dependencies
                    dep_script = script_for_dep(dependency)
                    m = Module(:__anon__)
                    eval(m, quote
                        using BinaryProvider
                        # Override BinaryProvider functionality so that it doesn't actually install anything
                        platform_key() = $platform
                        function write_deps_file(args...); end
                        function install(args...; kwargs...); end

                        # Include build.jl file to extract download_info
                        ARGS = [$(prefix.path)]
                        include_string($(dep_script))

                        # Grab the information we need in order to extract a manifest, then uninstall it
                        url, hash = download_info[platform_key()]
                        manifest_path = BinaryProvider.manifest_from_url(url; prefix=prefix)
                        BinaryProvider.uninstall(manifest_path; verbose=$verbose)
                    end)
                end

                # Once we're built up, go ahead and package this prefix out
                tarball_path, tarball_hash = package(prefix, joinpath(out_path, src_name); platform=platform, verbose=verbose, force=true)
                product_hashes[target] = (basename(tarball_path), tarball_hash)

                # Destroy the workspace
                rm(dirname(prefix.path); recursive=true)
            end

            # If the whole build_path is empty, then remove it too.  If it's not, it's probably
            # because some other build is doing something simultaneously with this target, and we
            # don't want to mess with their stuff.
            if isempty(readdir(build_path))
                rm(build_path; recursive=true)
            end
        end
    end

    if haskey(ENV, "TRAVIS") && !verbose
        run_travis_busytask = false
        wait(travis_busytask)
        println()
    end

    # Return our product hashes
    return product_hashes
end

function print_buildjl(io::IO, products::Vector, product_hashes::Dict,
                       bin_path::AbstractString)
    print(io, """
    using BinaryProvider # requires BinaryProvider 0.3.0 or later

    # Parse some basic command-line arguments
    const verbose = "--verbose" in ARGS
    const prefix = Prefix(get([a for a in ARGS if a != "--verbose"], 1, joinpath(@__DIR__, "usr")))
    """)

    # Print out products
    print(io, "products = [\n")
    for prod in products
        print(io, "    $(repr(prod)),\n")
    end
    print(io, "]\n\n")

    # Print binary locations/tarball hashes
    print(io, """
    # Download binaries from hosted location
    bin_prefix = "$bin_path"

    # Listing of files generated by BinaryBuilder:
    """)

    println(io, "download_info = Dict(")
    for platform in sort(collect(keys(product_hashes)))
        fname, hash = product_hashes[platform]
        pkey = platform_key(platform)
        println(io, "    $(pkey) => (\"\$bin_prefix/$(fname)\", \"$(hash)\"),")
    end
    println(io, ")\n")

    print(io, """
    # Install unsatisfied or updated dependencies:
    unsatisfied = any(!satisfied(p; verbose=verbose) for p in products)
    if haskey(download_info, platform_key())
        url, tarball_hash = download_info[platform_key()]
        if unsatisfied || !isinstalled(url, tarball_hash; prefix=prefix)
            # Download and install binaries
            install(url, tarball_hash; prefix=prefix, force=true, verbose=verbose)
        end
    elseif unsatisfied
        # If we don't have a BinaryProvider-compatible .tar.gz to download, complain.
        # Alternatively, you could attempt to install from a separate provider,
        # build from source or something even more ambitious here.
        error("Your platform \$(triplet(platform_key())) is not supported by this package!")
    end

    # Write out a deps.jl file that will contain mappings for our products
    write_deps_file(joinpath(@__DIR__, "deps.jl"), products)
    """)
end

function print_buildjl(build_dir::AbstractString, products::Vector,
                       product_hashes::Dict, bin_path::AbstractString)
    mkpath(joinpath(build_dir, "products"))
    open(joinpath(build_dir, "products", "build.jl"), "w") do io
        print_buildjl(io, products, product_hashes, bin_path)
    end
end

"""
If you have a sharded build on Github, it would be nice if we could get an auto-generated
`build.jl` just like if we build serially.  This function eases the pain by reconstructing
it from a releases page.
"""
function product_hashes_from_github_release(repo_name::AbstractString, tag_name::AbstractString;
                                            verbose::Bool = false)
    # Get list of files within this release
    release = gh_get_json(DEFAULT_API, "/repos/$(repo_name)/releases/tags/$(tag_name)", auth=github_auth)

    # Try to extract the platform key from each, use that to find all tarballs
    function can_extract_platform(filename)
        # Short-circuit build.jl because that's quite often there.  :P
        if filename == "build.jl"
            return false
        end

        unknown_platform = typeof(extract_platform_key(filename)) <: UnknownPlatform
        if unknown_platform && verbose
            Compat.@info("Ignoring file $(filename); can't extract its platform key")
        end
        return !unknown_platform
    end
    assets = [a for a in release["assets"] if can_extract_platform(a["name"])]

    # Download each tarball, hash it, and reconstruct product_hashes.
    product_hashes = Dict()
    mktempdir() do d
        for asset in assets
            # For each asset (tarball), download it
            filepath = joinpath(d, asset["name"])
            url = asset["browser_download_url"]
            BinaryProvider.download(url, filepath; verbose=verbose)

            # Hash it
            hash = open(filepath) do file
                return bytes2hex(sha256(file))
            end

            # Then fit it into our product_hashes
            file_triplet = triplet(extract_platform_key(asset["name"]))
            product_hashes[file_triplet] = (asset["name"], hash)

            if verbose
                Compat.@info("Calculated $hash for $(asset["name"])")
            end
        end
    end

    return product_hashes
end
