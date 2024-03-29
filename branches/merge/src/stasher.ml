(* $I1: Unison file synchronizer: src/stasher.ml $ *)
(* $I2: Last modified by lescuyer *)
(* $I3: Copyright 1999-2004 (see COPYING for details) $ *)

(*------------------------------------------------------------------------------------*)
(* Preferences for backing up and stashing *)
   
let debug = Util.debug "stasher"

let backuplocation = 
  Prefs.createString "backuplocation" "central"
    "where backups are stored ('local' or 'central')"
    ("This preference determines whether backups should be kept locally, near the "
     ^ "original files, or"
     ^" in a central directory specified by the \\texttt{backupdir} "
     ^"preference. If set to \\verb|local|, backups will be kept in "
     ^"the same directory as the original files, and if set to \\verb|central|,"
     ^" \\texttt{backupdir} will be used instead.")
    
let backup =
  Pred.create "backup"
    ("Including the preference \\texttt{-backup \\ARG{pathspec}} "
     ^ "causes Unison to keep backup files for each path that matches "
     ^ "\\ARG{pathspec}.  These backup files are kept in the "
     ^ "directory specified by the \\verb|backuplocation| preference. The backups are named "
     ^ "according to the \\verb|backupprefix| and \\verb|backupsuffix| preferences."
     ^ " The number of versions that are kept is determined by the "
     ^ "\\verb|maxbackups| preference."
     ^ "\n\n The syntax of \\ARG{pathspec} is described in "
     ^ "\\sectionref{pathspec}{Path Specification}.")
    
let _ = Pred.alias backup "mirror"

let backupnot =
  Pred.create "backupnot"
    ("The values of this preference specify paths or individual files or"
     ^ " regular expressions that should {\\em not} "
     ^ "be backed up, even if the {\\tt backup} preference selects "
     ^ "them---i.e., "
     ^ "it selectively overrides {\\tt backup}.  The same caveats apply here "
     ^ "as with {\\tt ignore} and {\tt ignorenot}.")

let _ = Pred.alias backupnot "mirrornot"
    
let shouldBackup p =
  let s = (Path.toString p) in
  Pred.test backup s && not (Pred.test backupnot s)
    
let backupprefix =
  Prefs.createString "backupprefix" ".unison."
    "prefix for the names of backup files"
    ("When a backup for a file \\verb|NAME| is created, it is stored "
     ^ "in a directory specified by \\texttt{backuplocation}, in a file called "
     ^ "\\texttt{backupprefix}\\verb|NAME|\\texttt{backupsuffix}."
     ^ " \\texttt{backupprefix} can include a directory name (causing Unison to "
     ^ "keep all backup files for a given directory in a subdirectory with this name), and both "
     ^ " \\texttt{backupprefix} and \\texttt{backupsuffix} can contain the string"
     ^ "\\ARG{\\$VERSION}, which will be replaced by the \\emph{age} of the backup "
     ^ "(1 for the most recent, 2 for the second most recent, and so on...)."
     ^ " This keyword is ignored if it appears in a directory name"
     ^ " in the prefix; if it  does not appear anywhere"
     ^ " in the prefix or the suffix, it will be automatically"
     ^ " placed at the beginning of the suffix.")
    
let backupsuffix =
  Prefs.createString "backupsuffix" ".$VERSION.bak"
    "a suffix to be added to names of backup files"
    ("See \\texttt{backupprefix} for full documentation.")

let backups =
  Prefs.createBool "backups" false
    "keep backup copies of all files (see also 'backup')"
    ("Setting this flag to true is equivalent to "
     ^" setting \\texttt{backuplocation} to \\texttt{local}"
     ^" and \\texttt{backup} to \\verb|Name *|.")

(* The following function is used to express the old backup preference, if set,
   in the terms of the new preferences *)
let translateOldPrefs () =
  match (Pred.extern backup, Pred.extern backupnot, Prefs.read backups) with
    ([], [], true) ->
      debug (fun () -> 
	Util.msg "backups preference set: translated into backup and backuplocation\n");
      Pred.intern backup ["Name *"]; 
      Prefs.set backuplocation "local"
  | (_, _, false) -> 
      ()
  | _ -> raise (Util.Fatal ( "Both old 'backups' preference and "
			    ^ "new 'backup' preference are set!"))
	
let maxbackups =
  Prefs.createInt "maxbackups" 2
    "number of backed up versions of a file"
    ("This preference specifies the number of backup versions that will "
     ^ "be kept by unison, for each path that matches the predicate "
     ^ "\\verb|backup|.  The default is 2.")
    
let _ = Prefs.alias maxbackups "mirrorversions"
let _ = Prefs.alias maxbackups "backupversions"
    
let backupdir =
  Prefs.createString "backupdir" ""
    "Directory for storing centralized backups"
    ("If this preference is set, Unison will use it as the name of the "
     ^ "directory used to store backup files specified by "
     ^ "the {\\tt backup} preference, when {\\tt backuplocation} is set"
     ^ " to \\verb|central|. It is checked {\\em after} the "
     ^ "{\\tt UNISONBACKUPDIR} environment variable.")

let backupDirectory () =
  try Fspath.canonize (Some (Unix.getenv "UNISONBACKUPDIR"))
  with Not_found ->
    try Fspath.canonize (Some (Unix.getenv "UNISONMIRRORDIR"))
    with Not_found ->
      if Prefs.read backupdir <> ""
      then Fspath.canonize (Some (Prefs.read backupdir))
      else Os.fileInUnisonDir "backup"

let backupcurrent =
  Pred.create "backupcurrent"
    ("Including the preference \\texttt{-backupcurrent \\ARG{pathspec}} "
     ^" causes Unison to keep a backup of the {\\em current} version of every file "
     ^ "matching \\ARG{pathspec}.  "
     ^" This file will be saved as a backup with version number 000. Such"
     ^" backups can be used as inputs to external merging programs, for instance.  See "
     ^ "the documentatation for the \\verb|merge| preference."
     ^" For more details, see \\sectionref{merge}{Merging Conflicting Versions}."
     ^"\n\n The syntax of \\ARG{pathspec} is described in "
     ^ "\\sectionref{pathspec}{Path Specification}.")

let shouldBackupCurrent p = Pred.test backupcurrent (Path.toString p)

(*------------------------------------------------------------------------------------*)

(* NB: We use Str.regexp here because we need group matching to retrieve
   and increment version numbers from backup file names. We only use
   it here, though: to check if a path should be backed up or ignored, we
   use Rx instead. *)

(* regular expressions for backups, based on current preferences *)
let version_rx = "\\([0-9]+\\)"

let dir_rx = ref None
let prefix_rx = ref ""
let suffix_rx = ref ""
    
(* A tuple of string option * string * string, describing a regular
   expression that matches the filenames of unison backups according
   to the current preferences. The first regexp is an option to match
   local directory, if ever, in which backups are stored ; the second
   one matches the prefix, the third the suffix.                     *)
let backup_rx () =
  let sp = Prefs.read backupprefix in
  let suffix = Str.quote (Prefs.read backupsuffix) in
  let (udir, uprefix) =
    ((match Filename.dirname sp with "." -> "" | s -> (Fileutil.bs2fs s)^"/"), 
     Filename.basename sp) in
  let (dir, prefix) = 
    ((match udir with "" -> None | _ -> Some(Str.quote udir)), Str.quote uprefix) in
  
  if Str.string_match (Str.regexp ".*\\\\\\$VERSION.*") (prefix^suffix) 0 then begin
    (dir,
     Str.global_replace (Str.regexp "\\\\\\$VERSION") version_rx prefix,
     Str.global_replace (Str.regexp "\\\\\\$VERSION") version_rx suffix)
  end else
    (dir, prefix, version_rx^suffix)
   
(* This function updates the regular expressions for backups' filenames *)   
let updateRE () = 
  let (a,b,c) = backup_rx () in 
  debug ( fun () -> 
      Util.msg "Regular Expressions for backups updated:\n ";
      Util.msg "dir_rx: %s\n prefix_rx: %s\n suffix_rx: %s\n"
        (match a with None -> "MISSING" | Some s -> s) b c);
  (dir_rx := a; prefix_rx := b; suffix_rx := c)
    
(* We ignore files whose name ends in .unison.bak, since people may still have these lying around
   from using previous versions of Unison. *)
let oldBackupPrefPathspec = "Name *.unison.bak"

(* This function creates Rx regexps based on the preferences to ignore
   backups of old and current versions.*)
let addBackupFilesToIgnorePref () =
  let regexp_to_rx s =
   Str.global_replace (Str.regexp "\\\\(") ""
     (Str.global_replace (Str.regexp "\\\\)") "" s) in
  let (full, dir) =
    let d = 
      match !dir_rx with 
	None -> "/" 
      | Some s -> regexp_to_rx s in
    let p = regexp_to_rx !prefix_rx in
    let s = regexp_to_rx !suffix_rx in
    (".*"^p^".*"^s, ".*"^(String.sub d 0 (String.length d - 1))) in
  let theRegExp = 
    match !dir_rx with 
      None   -> "Regex " ^ full 
    | Some _ -> "Regex " ^ dir in
  debug (fun () -> 
     Util.msg "New pattern being added to ignore preferences: %s\n" theRegExp);
  let oldRE = Pred.extern Globals.ignore in
  let newRE = theRegExp::oldBackupPrefPathspec::oldRE in
  Pred.intern Globals.ignore newRE

(*------------------------------------------------------------------------------------*)

(* We use references for functions that compute the prefixes and suffixes
   in order to avoid using functions from the Str module each time.       *)
let prefix_string = ref (fun i -> "")
let suffix_string = ref (fun i -> "")
    
(* This function updates the function used to create prefixes and suffixes
   for naming backup files, according to the preferences. *)
let updatePrefixAndSuffix () =
  let sp = Prefs.read backupprefix in
  let suffix = Prefs.read backupsuffix in
  
  let version i = Printf.sprintf "%03d" i in
  
  let version_appears_once s mandatory=
    let regexp = Str.regexp "\\$VERSION" in
    match Str.full_split regexp s with
      [] -> (fun _ -> "")
    | [Str.Text t] ->  
	if mandatory then
	  raise (Util.Fatal "Either backupprefix or backupsuffix must contain $VERSION")
	else
	  (fun _ -> t)
    | [Str.Delim _; Str.Text t] -> 
	(fun i -> Printf.sprintf "%s%s" (version i) t)
    | [Str.Text t; Str.Delim _] ->
	(fun i -> Printf.sprintf "%s%s" t (version i))
    | [Str.Text t; Str.Delim _; Str.Text t'] ->
	(fun i -> Printf.sprintf "%s%s%s" t (version i) t')
    | _ -> 
	raise (Util.Fatal ("The tag $VERSION should only appear "
			   ^"once in the backups(prefix|suffix) preferences."))
  in
  
  let (dir, prefix) =
    ((match Filename.dirname sp with "." -> "" | s -> s), Filename.basename sp) in
  
  let _ = version_appears_once (prefix^suffix) true in
  prefix_string := version_appears_once prefix false;
  suffix_string := version_appears_once suffix false;
  debug (fun () -> 
           Util.msg "Prefix and Suffix for backup filenames have been updated.\n")
	  
(* Generates a file name for a backup file.  If backup file already exists,
   the old file will be renamed with the count incremented.  The newest
   backup file is always the one with version number 1, larger numbers mean
   older files. *)
let backupPath fspath path =
  let fspath = 
    match Prefs.read backuplocation with
      "central" -> backupDirectory ()
    | "local" -> fspath
    |  _ -> raise (Util.Fatal ("backuplocation preference should be set to 'central'"
			       ^ "or 'local'.")) in
  let rec f i =
    let (prefix, suffix) = (!prefix_string i, !suffix_string i) in
    let tempPath = 
      Path.addSuffixToFinalName 
	(Path.addPrefixToFinalName path prefix) suffix in
    if Os.exists fspath tempPath && i < Prefs.read maxbackups then
      Os.rename fspath tempPath fspath (f (i + 1));
    tempPath in
  (fspath, f 1)
    
(* backdir may be in subdirectories of fspath, so we recursively 
   create them in order to avoid error in system calls to Os. *)
let rec mkdirectories fspath backdir =
  match Path.deconstructRev backdir with
    None -> ()
  | Some (_, parent) ->
      mkdirectories fspath parent;
      let props = (Fileinfo.get false fspath Path.empty).Fileinfo.desc in
      if not(Os.exists fspath backdir) then Os.createDir fspath backdir props

(*------------------------------------------------------------------------------------*)
	  
(* Removes file at fspath/path and backs it up before if required.
   To check if the file has to be backed up and to create the
   name of the backup file, fakeFspath/fakePath is used instead.
   This allows us to deal directly with temporary files. *)
let removeAndBackupAsAppropriate fspath path fakeFspath fakePath =
  debug ( fun () -> Util.msg
      "removeAndBackupAsAppropriate: (%s,%s), for real path (%s,%s)\n"
      (Fspath.toString fspath)
      (Path.toString path)
      (Fspath.toString fakeFspath)
      (Path.toString fakePath));
  if not (Os.exists fspath path) then 
    debug (fun () -> Util.msg "File %s in %s does not exist, no need to back up\n"  
	(Path.toString path) (Fspath.toString fspath))
  else
    if shouldBackup fakePath then begin
      let (backRoot, backPath) = backupPath fakeFspath fakePath in
      (match Path.deconstructRev backPath with
	None -> ()
      | Some (n, dir) when dir = Path.empty -> ()
      | Some (n, backdir) -> mkdirectories backRoot backdir);
      debug (fun () -> Util.msg "Backing up [%s] in [%s] to [%s] in [%s]\n" 
	  (Path.toString fakePath)
	  (Fspath.toString fakeFspath)
	  (Path.toString backPath)
	  (Fspath.toString backRoot));
      Os.rename fspath path backRoot backPath
    end else begin
      Printf.printf "File %s in %s will not be backed up.\n" 
	(Path.toString fakePath) 
	(Fspath.toString fakeFspath);
      Os.delete fspath path
    end
	
(*------------------------------------------------------------------------------------*)

let stashDirectory fspath =
  match Prefs.read backuplocation with
    "central" -> backupDirectory ()
  | "local" -> fspath
  |  _ -> raise (Util.Fatal ("backuplocation preference should be set"
			     ^"to central or local."))
	
let findStash path i =
  (* if backups are kept centrally, the current version has exactly
     th same name as the original, for convenience. *)
  if i=0 && Prefs.read backuplocation = "central" then
    path
  else
    Path.addSuffixToFinalName 
      (Path.addPrefixToFinalName path (!prefix_string i))
      (!suffix_string i) 
    
let stashPath fspath path =
  let fspath = stashDirectory fspath in
  let tempPath = findStash path 0 in
  if Os.exists fspath tempPath then 
    if shouldBackup path then 
      (* this is safe because this is done *after* backup *)
      Os.delete fspath tempPath 
    else begin
      (* we still a keep a second backup just in case something go bad *)
      Trace.debug "verbose" 
	(fun () -> Util.msg "Creating a safety backup for (%s, %s)\n" 
	    (Fspath.toString fspath) (Path.toString path));
      let olBackup = findStash path 1 in
      if Os.exists fspath olBackup then Os.delete fspath olBackup;
      Os.rename fspath tempPath fspath olBackup
    end;
  (fspath, tempPath)

let stashCurrentVersionLocal fspath path =
  debug (fun () -> 
    Util.msg "stashCurrentVersion of %s in %s\n" 
      (Path.toString path) (Fspath.toString fspath));
  if Os.exists fspath path then
    let dirstat = (Fspath.stat (Fspath.concat fspath path))in
    if dirstat.Unix.LargeFile.st_kind = Unix.S_DIR then
      debug (fun () -> Util.msg "Stashing aborted because file is a directory\n")
    else
      if shouldBackupCurrent path then
	let (stashDir, stashPath) = stashPath fspath path in
	let info = Fileinfo.get false fspath path in
	Copy.localFile 
	  fspath path 
	  stashDir stashPath stashPath 
	  `Copy 
	  info.Fileinfo.desc
	  (Osx.ressLength info.Fileinfo.osX.Osx.ressInfo)
	  None
      
let stashCurrentVersionOnRoot: Common.root -> Path.local -> unit Lwt.t =
  Remote.registerRootCmd
    "stashCurrentVersion"
    (fun (fspath, path) ->
      Lwt.return (stashCurrentVersionLocal fspath path))
    
let stashCurrentVersion path =
  Lwt_unix.run (
  Globals.allRootsIter
    (fun r -> stashCurrentVersionOnRoot r path)
    )

(*------------------------------------------------------------------------------------*)    
    
(* This function tries to find a backup of a recent version of the file at location
   (fspath, path) in the current replica, matching the given fingerprint. If no file
   is found, then the functions returns None *without* searching on the other replica *)
let getRecentVersion fspath path fingerprint =
  debug (fun () ->
    Util.msg "getRecentVersion of %s in %s\n" 
      (Path.toString path) 
      (Fspath.toString fspath));
  let dir = stashDirectory fspath in
  let rec aux_find i =
    let path = findStash path i in
    if Os.exists dir path &&
      (let dig = Os.fingerprint dir path (Fileinfo.get false dir path) in 
      dig = fingerprint)
    then begin
      debug (fun () ->
	Util.msg "recent version %s found in %s\n" 
	  (Path.toString path) 
	  (Fspath.toString dir));
      Some (Fspath.concat dir path)
    end else
      if i = Prefs.read maxbackups then begin
	debug (fun () ->
	  Util.msg "No recent version was available for %s on this root.\n"
	    (Fspath.toString (Fspath.concat fspath path)));
	None
      end else
	aux_find (i+1)
  in
  aux_find 0
    
(*------------------------------------------------------------------------------------*)    

(* This function initializes the Stasher module according to the preferences
   defined in the profile. It should be called whenever a profile is reloaded. *)
let initBackups () =
  translateOldPrefs ();
  updateRE ();
  addBackupFilesToIgnorePref ();
  updatePrefixAndSuffix ();
  
  (* if the preference for backuplocation is set to central *)
  (* then we are likely to need a backup directory in the   *)
  (* .unison directory ; we deal for this here.             *)
  let backupDir = Os.fileInUnisonDir "backup" in
  if (Prefs.read backuplocation = "central") && 
    not(Os.exists backupDir Path.empty) then
    Os.createDir backupDir Path.empty Props.dirDefault
