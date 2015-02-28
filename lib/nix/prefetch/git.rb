require "fileutils"
require "shellwords"

module Nix
  module Prefetch
    class Git
      class Result
        attr_reader :hash
        attr_reader :full_revision
        attr_reader :path

        def initialize(attrs)
          attrs.each_pair do |key, val|
            instance_variable_set(:"@#{key}", val)
          end
        end
      end

      def fetch(type, url, rev, opts={})
        Nix::Hash.assert_valid_type(type)

        name          = opts[:name] || "git-export"
        expected_hash = opts[:hash] || nil
        leave_dot_git = opts[:leave_dot_git] || false
        deep_clone    = opts[:deep_clone] || false

        if expected_hash
          path = Store.fixed_path(expected_hash, name)

          if Store.invalid_paths([path]).empty?
            return Result.new(
              :hash => expected_hash,
              :path => path,
            )
          end
        end

        Dir.mktmpdir do |dir|
          dir = File.join(dir, name)
          FileUtils.mkdir_p(dir)

          # Perform the checkout.
          res = clone_user_rev(dir, url, rev, leave_dot_git, deep_clone)

          # Compute the hash.
          hash = Nix::Hash.hash_path(type, dir)

          # Add the downloaded file to the Nix store.
          path = Nix::Store::add_fixed(hash, dir, :recursive => true)

          Result.new(res.merge(
            :hash => hash,
            :path => path,
          ))
        end
      end

      private

      def clone(dir, url, hash, ref, deep_clone)
        hash, ref = resolve_hash_and_ref(hash, ref)

        Dir.chdir(dir) do
          # Initialize the repository.
          init_remote(url)

          # Download data from the repository.
          if !deep_clone && ref
            checkout_ref(hash, ref)
          else
            checkout_hash(hash, ref)
          end

          full_revision = sh("git rev-parse #{(hash || ref).shellescape} 2> /dev/null || git rev-parse refs/heads/fetchgit").split("\n").last

          # Checkout linked sources.
          if fetch_submodules
            init_submodules(deep_clone)
          end

          { :full_revision => full_revision }
        end
      end

      def resolve_hash_and_ref(hash, ref)
        if !hash && ref
          hash = hash_from_ref(ref)
        elsif !ref && hash
          ref = ref_from_hash(hash)
        else
          fail "no hash or ref given"
        end
        [hash, ref]
      end

      def init_remote(url)
        sh "git init"
        sh "git remote add origin #{url}"
      end

      def ref_from_hash(hash)
        refs = sh "git ls-remote origin"
        line = refs.split("\n").detect { |line| line.split("\t")[0] == hash }
        if line
          line.split("\t")[1]
        end
      end

      def hash_from_ref(ref)
        refs = sh("git ls-remote origin").split("\n").compact
        line = refs.split("\n").detect { |line| line.split("\t")[1] == ref }
        if line
          line.split("\t")[0]
        end
      end

      def checkout_hash(hash, ref)
        sh "git fetch --progress origin"
        sh "git checkout -b fetchgit #{hash.shellescape}"
      end

      def checkout_ref(hash, ref)
        sh "git fetch --progress --depth 1 origin +#{ref.shellescape}"
        sh "git checkout -b fetchgit FETCH_HEAD"
      end

      def init_submodules(deep_clone)
        # Add urls into .git/config file
        sh "git submodule init"

        # list submodule directories and their hashes
        lines = sh("git submodule status").split("\n")
        lines.each do |line|
          hash, dir = line.split(" ")
          settings = sh("git config -f .gitmodules --get-regexp 'submodule\\..*\\.path'").split("\n")
          settings.detect {|path| path =~ /^(.*)\.path #{dir}$/}
          dir = Regexp.last_match[1]
          clone(dir, url, hash, nil, deep_clone)
        end
      end

      def make_deterministic_repo(repo)
        Dir.chdir(repo) do
          # Remove files that contain timestamps or otherwise have non-deterministic
          # properties.
          [".git/logs/", ".git/hooks/", ".git/index", ".git/FETCH_HEAD",
           ".git/ORIG_HEAD", ".git/refs/remotes/origin/HEAD", ".git/config"
          ].each do |p|
            FileUtils.rm_rf(p)
          end

          # Remove all remote branches.
          branches = sh("git branch -r").split("\n")
          branches.each do |b|
            sh("git branch -rD #{b.shellescape} >&2")
          end

          # Remove tags not reachable from HEAD. If we're exactly on a tag, don't
          # delete it.
          maybe_tag = sh("git tag --points-at HEAD")
          tags = sh("git tag --contains HEAD").split("\n")
          tags.each do |t|
            if t != maybe_tag
              sh("git tag -d #{t.shellescape}")
            end
          end

          # Do a full repack. Must run single-threaded, or else we loose determinism.
          sh("git config pack.threads 1")
          sh("git repack -A -d -f")
          FileUtils.rm_f(".git/config")

          # Garbage collect unreferenced objects.
          sh("git gc --prune=all")
        end
      end

      def clone_user_rev(dir, url, rev, leave_dot_git, deep_clone)
        # Perform the checkout.
        res =
          if rev.start_with?("refs/")
            clone(dir, url, nil, rev, deep_clone)
          elsif rev =~ /^[0-9a-f]+$/
            clone(dir, url, rev, nil, deep_clone)
          end

        gitdirs = Dir.glob("**/.git")
        if leave_dot_git
          gitdirs.each do |gitdir|
            make_deterministic_repo(File.readlink(gitdir))
          end
        else
          gitdirs.each do |gitdir|
            FileUtils.rmdir(gitdir)
          end
        end

        res
      end

      def sh(cmd)
        stdout = `#{cmd}`
        unless $?.success?
          fail "shell command #{cmd.inspect} exitted with #{$?.exitstatus}"
        end
        return stdout.chomp
      end
    end
  end
end
