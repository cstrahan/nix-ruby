require "fileutils"

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

      def fetch(url, rev)
        if expected_hash
          path = Store.fixed_path(expected_hash, name || "git-export")

          unless Store.invalid_paths([path]).empty?
            return Result.new(
              :hash => expected_hash,
              :path => path,
            )
          end
        end

        Dir.mktmpdir do |dir|
          dir = File.join(dir, name || "git-export")
          FileUtils.mkdir_p(dir)

          # Perform the checkout.
          clone_user_rev(dir, url, rev)

          # Compute the hash.
          hash = sh("nix-hash --type #{hash_type.shellescape} --base32 #{dir.shellescape}")

          # Add the downloaded file to the Nix store.
          path = sh("nix-store --add-fixed --recursive #{hash_type.shellescape} #{dir.shellescape}")

          Result.new(attrs)
        end
      end

      private

      def clone(dir, url, hash, ref)
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
            init_submodules
          end
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

      def init_submodules
        # Add urls into .git/config file
        sh "git submodule init"

        # list submodule directories and their hashes
        lines = sh("git submodule status").split("\n")
        lines.each do |line|
          hash, dir = line.split(" ")
          settings = sh("git config -f .gitmodules --get-regexp 'submodule\\..*\\.path'").split("\n")
          settings.detect {|path| path =~ /^(.*)\.path #{dir}$/}
          dir = Regexp.last_match[1]
          clone(dir, url, hash, nil)
        end
      end

      def clone_user_rev(dir, url, rev)
        # Perform the checkout.
        if rev.start_with?("refs/")
          clone(dir, url, nil, rev)
        elsif rev =~ /^[0-9a-f]+$/
          clone(dir, url, rev, nil)
        end
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
