{config, ...}: let
  l = config.lib;

  # INTERNAL

  # Calls any function with an attrset arugment, even if that function
  # doesn't accept an attrset argument, in which case the arguments are
  # recursively applied as parameters.
  # For this to work, the function parameters defined by the called function
  # must always be ordered alphabetically.
  callWithAttrArgs = func: args: let
    applyParamsRec = func: params:
      if l.length params == 1
      then func (l.head params)
      else
        applyParamsRec
        (func (l.head params))
        (l.tail params);
  in
    if l.functionArgs func == {}
    then applyParamsRec func (l.attrValues args)
    else func args;

  # prepare source tree for executing discovery phase
  # produces this structure:
  # {
  #   files = {
  #     "package.json" = {
  #       relPath = "package.json"
  #       fullPath = "${source}/package.json"
  #       content = ;
  #       jsonContent = ;
  #       tomlContent = ;
  #     }
  #   };
  #   directories = {
  #     "packages" = {
  #       relPath = "packages";
  #       fullPath = "${source}/packages";
  #       files = {
  #
  #       };
  #       directories = {
  #
  #       };
  #     };
  #   };
  # }
  prepareSourceTreeInternal = sourceRoot: relPath: name: depth: let
    relPath' = relPath;
    fullPath' = "${toString sourceRoot}/${relPath}";
    current = l.readDir fullPath';

    fileNames =
      l.filterAttrs (n: v: v == "regular") current;

    directoryNames =
      l.filterAttrs (n: v: v == "directory") current;

    makeNewPath = prefix: name:
      if prefix == ""
      then name
      else "${prefix}/${name}";

    directories =
      l.mapAttrs
      (dname: _:
        prepareSourceTreeInternal
        sourceRoot
        (makeNewPath relPath dname)
        dname
        (depth - 1))
      directoryNames;

    files =
      l.mapAttrs
      (fname: _: rec {
        name = fname;
        fullPath = "${fullPath'}/${fname}";
        relPath = makeNewPath relPath' fname;
        content = readTextFile fullPath;
        jsonContent = l.fromJSON content;
        tomlContent = l.fromTOML content;
      })
      fileNames;

    # returns the tree object of the given sub-path
    getNodeFromPath = path: let
      cleanPath = l.removePrefix "/" path;
      pathSplit = l.splitString "/" cleanPath;
      dirSplit = l.init pathSplit;
      leaf = l.last pathSplit;
      error = throw ''
        Failed while trying to navigate to ${path} from ${fullPath'}
      '';

      dirAttrPath =
        l.init
        (l.concatMap
          (x: [x] ++ ["directories"])
          dirSplit);

      dir =
        if (l.length dirSplit == 0) || dirAttrPath == [""]
        then self
        else if ! l.hasAttrByPath dirAttrPath directories
        then error
        else l.getAttrFromPath dirAttrPath directories;
    in
      if path == ""
      then self
      else if dir ? directories."${leaf}"
      then dir.directories."${leaf}"
      else if dir ? files."${leaf}"
      then dir.files."${leaf}"
      else error;

    self =
      {
        inherit files getNodeFromPath name relPath;

        fullPath = fullPath';
      }
      # stop recursion if depth is reached
      // (l.optionalAttrs (depth > 0) {
        inherit directories;
      });
  in
    self;

  # determines if version v1 is greater than version v2
  versionGreater = v1: v2: l.compareVersions v1 v2 == 1;

  # EXPORTED

  # calculate an invalidation hash for given source translation inputs
  calcInvalidationHash = {
    project,
    source,
    translator,
    translatorArgs,
    config,
  }: let
    sanitizedPackagesDir = sanitizeRelativePath config.packagesDir;

    localOverridesDirs =
      l.filter
      (oDir: ! l.hasPrefix l.storeDir oDir)
      config.overridesDirs;

    sanitizedOverridesDirs = l.map sanitizeRelativePath localOverridesDirs;

    filter = path: _:
      (baseNameOf path != "flake.nix")
      && l.match ''.*/${sanitizedPackagesDir}'' path == null
      && (l.any
        (oDir: l.match ''.*/${oDir}'' path == null)
        sanitizedOverridesDirs);

    ca-source = l.path {
      path = source;
      name = "dream2nix-package-source";
      inherit filter;
    };
  in
    l.hashString "sha256" ''
      ${ca-source}
      ${l.toJSON project}
      ${translator}
      ${l.toString
        (l.mapAttrsToList (k: v: "${k}=${l.toString v}") translatorArgs)}
    '';

  # call a function using arguments defined by the env var FUNC_ARGS
  callViaEnv = func: let
    funcArgs' = l.fromJSON (l.readFile (l.getEnv "FUNC_ARGS"));
    # re-create string contexts for store paths
    funcArgs =
      l.mapAttrsRecursive
      (path: val:
        if
          l.isString val
          && l.hasPrefix "/nix/store/" val
        then l.path {path = val;}
        else val)
      funcArgs';
  in
    callWithAttrArgs func funcArgs;

  # Returns true if every given pattern is satisfied by at least one file name
  # inside the given directory.
  # Sub-directories are not recursed.
  containsMatchingFile = patterns: dir:
    l.all
    (pattern: l.any (file: l.match pattern file != null) (listFiles dir))
    patterns;

  # directory names of a given directory
  dirNames = dir: l.attrNames (l.filterAttrs (name: type: type == "directory") (builtins.readDir dir));

  # ensures that value is attrset but not a derivation
  isNotDrvAttrs = val:
    l.isAttrs val && (val.type or "") != "derivation";

  # picks the latest version from a list of version strings
  latestVersion = versions:
    l.head (l.sort versionGreater versions);

  listDirs = path: l.attrNames (l.filterAttrs (n: v: v == "directory") (builtins.readDir path));

  listFiles = path: l.attrNames (l.filterAttrs (n: v: v == "regular") (builtins.readDir path));

  mergeFlakes = flakes: l.foldl' recursiveUpdateUntilDrv {} flakes;

  nameVersionPair = name: version: {inherit name version;};

  prepareSourceTree = {
    source,
    depth ? 10,
  }:
    prepareSourceTreeInternal source "" "" depth;

  readTextFile = file: l.replaceStrings ["\r\n"] ["\n"] (l.readFile file);

  # like nixpkgs recursiveUpdateUntil, but with the depth as a stop condition
  recursiveUpdateUntilDepth = depth: lhs: rhs:
    l.recursiveUpdateUntil (path: _: _: (l.length path) > depth) lhs rhs;

  recursiveUpdateUntilDrv =
    l.recursiveUpdateUntil
    (_: l: r: !(isNotDrvAttrs l && isNotDrvAttrs r));

  sanitizeRelativePath = path:
    l.removePrefix "/" (l.toString (l.toPath "/${path}"));

  sanitizePath = path: let
    absolute = (l.substring 0 1 path) == "/";
    sanitizedRelPath = l.removePrefix "/" (l.toString (l.toPath "/${path}"));
  in
    if absolute
    then "/${sanitizedRelPath}"
    else sanitizedRelPath;

  systemsFromFile = {
    file,
    config,
  }:
    if ! l.pathExists file
    then let
      relPathFile =
        l.removePrefix (l.toString config.projectRoot) (l.toString file);
    in
      throw ''
        The system for your flake.nix is not initialized yet.
        Please execute the following command to initialize it:

        nix eval --impure --raw --expr 'builtins.currentSystem' > .${relPathFile} && git add .${relPathFile}
      ''
    else l.filter (l: l != "") (l.splitString "\n" (l.readFile file));

  traceJ = toTrace: eval: l.trace (l.toJSON toTrace) eval;

  mkFunction = {type, ...} @ attrs:
    l.mkOption (
      attrs
      // {
        type = l.types.uniq (l.types.functionTo attrs.type);
      }
    );
in {
  config.dlib = {
    inherit
      calcInvalidationHash
      callViaEnv
      containsMatchingFile
      dirNames
      latestVersion
      listDirs
      listFiles
      mergeFlakes
      mkFunction
      nameVersionPair
      prepareSourceTree
      readTextFile
      recursiveUpdateUntilDepth
      recursiveUpdateUntilDrv
      sanitizePath
      sanitizeRelativePath
      systemsFromFile
      traceJ
      isNotDrvAttrs
      ;
  };
}
