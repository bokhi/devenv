{ pkgs, config, lib, inputs, ... }:

let
  cfg = config.languages.python;

  requirements = pkgs.writeText "requirements.txt" (
    if lib.isPath cfg.venv.requirements
    then builtins.readFile cfg.venv.requirements
    else cfg.venv.requirements
  );

  nixpkgs-python = inputs.nixpkgs-python or (throw ''
    To use languages.python.version, you need to add the following to your devenv.yaml:

      inputs:
        nixpkgs-python:
          url: github:cachix/nixpkgs-python
  '');

  initVenvScript = pkgs.writeShellScript "init-venv.sh" ''
    # Make sure any tools are not attempting to use the python interpreter from any
    # existing virtual environment. For instance if devenv was started within an venv.
    unset VIRTUAL_ENV

    VENV_PATH="${config.env.DEVENV_STATE}/venv"

    if [ ! -L "$VENV_PATH"/devenv-profile ] \
    || [ "$(${pkgs.coreutils}/bin/readlink "$VENV_PATH"/devenv-profile)" != "${config.devenv.profile}" ]
    then
      if [ -d "$VENV_PATH" ]
      then
        echo "Rebuilding Python venv..."
        ${pkgs.coreutils}/bin/rm -rf "$VENV_PATH"
      fi
      ${lib.optionalString cfg.poetry.enable ''
        [ -f "${config.env.DEVENV_STATE}/poetry.lock.checksum" ] && rm ${config.env.DEVENV_STATE}/poetry.lock.checksum
      ''}
      ${cfg.package.interpreter} -m venv "$VENV_PATH"
      ${pkgs.coreutils}/bin/ln -sf ${config.devenv.profile} "$VENV_PATH"/devenv-profile
    fi
    source "$VENV_PATH"/bin/activate
    ${lib.optionalString (cfg.venv.requirements != null) ''
      "$VENV_PATH"/bin/pip install -r ${requirements} ${lib.optionalString cfg.venv.quiet ''
        --quiet
      ''}
    ''}
  '';

  initPoetryScript = pkgs.writeShellScript "init-poetry.sh" ''
    function _devenv-init-poetry-venv()
    {
      # Make sure any tools are not attempting to use the python interpreter from any
      # existing virtual environment. For instance if devenv was started within an venv.
      unset VIRTUAL_ENV

      # Make sure poetry's venv uses the configured python executable.
      ${cfg.poetry.package}/bin/poetry env use --no-interaction --quiet ${cfg.package.interpreter}
    }

    function _devenv-poetry-install()
    {
      local POETRY_INSTALL_COMMAND=(${cfg.poetry.package}/bin/poetry install --no-interaction ${lib.concatStringsSep " " cfg.poetry.install.arguments})
      # Avoid running "poetry install" for every shell.
      # Only run it when the "poetry.lock" file or python interpreter has changed.
      # We do this by storing the interpreter path and a hash of "poetry.lock" in venv.
      local ACTUAL_POETRY_CHECKSUM="${cfg.package.interpreter}:$(${pkgs.nix}/bin/nix-hash --type sha256 pyproject.toml):$(${pkgs.nix}/bin/nix-hash --type sha256 poetry.lock):''${POETRY_INSTALL_COMMAND[@]}"
      local POETRY_CHECKSUM_FILE="$DEVENV_ROOT"/.venv/poetry.lock.checksum
      if [ -f "$POETRY_CHECKSUM_FILE" ]
      then
        read -r EXPECTED_POETRY_CHECKSUM < "$POETRY_CHECKSUM_FILE"
      else
        EXPECTED_POETRY_CHECKSUM=""
      fi

      if [ "$ACTUAL_POETRY_CHECKSUM" != "$EXPECTED_POETRY_CHECKSUM" ]
      then
        if ''${POETRY_INSTALL_COMMAND[@]}
        then
          echo "$ACTUAL_POETRY_CHECKSUM" > "$POETRY_CHECKSUM_FILE"
        else
          echo "Poetry install failed. Run 'poetry install' manually."
        fi
      fi
    }

    if [ ! -f pyproject.toml ]
    then
      echo "No pyproject.toml found. Run 'poetry init' to create one." >&2
    else
      _devenv-init-poetry-venv
      ${lib.optionalString cfg.poetry.install.enable ''
        _devenv-poetry-install
      ''}
      ${lib.optionalString cfg.poetry.activate.enable ''
        source "$DEVENV_ROOT"/.venv/bin/activate
      ''}
    fi
  '';
in
{
  options.languages.python = {
    enable = lib.mkEnableOption "tools for Python development";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.python3;
      defaultText = lib.literalExpression "pkgs.python3";
      description = "The Python package to use.";
    };

    version = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        The Python version to use.
        This automatically sets the `languages.python.package` using [nixpkgs-python](https://github.com/cachix/nixpkgs-python).
      '';
      example = "3.11 or 3.11.2";
    };

    venv.enable = lib.mkEnableOption "Python virtual environment";

    venv.requirements = lib.mkOption {
      type = lib.types.nullOr (lib.types.either lib.types.lines lib.types.path);
      default = null;
      description = ''
        Contents of pip requirements.txt file.
        This is passed to `pip install -r` during `devenv shell` initialisation.
      '';
    };

    venv.quiet = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Whether `pip install` should avoid outputting messages during devenv initialisation.";
    };

    poetry = {
      enable = lib.mkEnableOption "poetry";
      install = {
        enable = lib.mkEnableOption "poetry install during devenv initialisation";
        arguments = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          description = "Command line arguments pass to `poetry install` during devenv initialisation.";
          internal = true;
        };
        installRootPackage = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Whether the root package (your project) should be installed. See `--no-root`";
        };
        quiet = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Whether `poetry install` should avoid outputting messages during devenv initialisation.";
        };
        groups = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          description = "Which dependency-groups to install. See `--with`.";
        };
        extras = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          description = "Which extras to install. See `--extras`.";
        };
        allExtras = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Whether to install all extras. See `--all-extras`.";
        };
      };
      activate.enable = lib.mkEnableOption "activate the poetry virtual environment automatically";

      package = lib.mkOption {
        type = lib.types.package;
        default = pkgs.poetry;
        defaultText = lib.literalExpression "pkgs.poetry";
        description = "The Poetry package to use.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    languages.python.poetry.install.enable = lib.mkIf cfg.poetry.enable (lib.mkDefault true);
    languages.python.poetry.install.arguments =
      lib.optional (!cfg.poetry.install.installRootPackage) "--no-root" ++
      lib.optional cfg.poetry.install.quiet "--quiet" ++
      lib.optionals (cfg.poetry.install.groups != [ ]) [ "--with" ''"${lib.concatStringsSep "," cfg.poetry.install.groups}"'' ] ++
      lib.optionals (cfg.poetry.install.extras != [ ]) [ "--extras" ''"${lib.concatStringsSep " " cfg.poetry.install.extras}"'' ] ++
      lib.optional cfg.poetry.install.allExtras "--all-extras";

    languages.python.poetry.activate.enable = lib.mkIf cfg.poetry.enable (lib.mkDefault true);

    languages.python.package = lib.mkMerge [
      (lib.mkIf (cfg.version != null) (nixpkgs-python.packages.${pkgs.stdenv.system}.${cfg.version} or (throw "Unsupported Python version, see https://github.com/cachix/nixpkgs-python#supported-python-versions")))
    ];

    packages = [
      cfg.package
    ] ++ (lib.optional cfg.poetry.enable cfg.poetry.package);

    env = lib.optionalAttrs cfg.poetry.enable {
      # Make poetry use DEVENV_ROOT/.venv
      POETRY_VIRTUALENVS_IN_PROJECT = "true";
      # Make poetry create the local virtualenv when it does not exist.
      POETRY_VIRTUALENVS_CREATE = "true";
      # Make poetry stop accessing any other virtualenvs in $HOME.
      POETRY_VIRTUALENVS_PATH = "/var/empty";
    };

    enterShell = lib.concatStringsSep "\n" ([
      ''
        export PYTHONPATH="$DEVENV_PROFILE/${cfg.package.sitePackages}''${PYTHONPATH:+:$PYTHONPATH}"
      ''
    ] ++
    (lib.optional cfg.venv.enable ''
      source ${initVenvScript}
    '') ++ (lib.optional cfg.poetry.install.enable ''
      source ${initPoetryScript}
    '')
    );
  };
}
