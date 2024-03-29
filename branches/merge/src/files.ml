(* $I1: Unison file synchronizer: src/files.ml $ *)
(* $I2: Last modified by bcpierce on Fri, 26 Nov 2004 19:34:28 -0500 $ *)
(* $I3: Copyright 1999-2004 (see COPYING for details) $ *)

open Common
open Lwt
open Fileinfo
  
let debug = Trace.debug "files"
let debugverbose = Trace.debug "verbose"
    
(* ------------------------------------------------------------ *)
    
let commitLogName = Util.fileInHomeDir "DANGER.README"
    
let writeCommitLog source target tempname =
  let sourcename = Fspath.toString source in
  let targetname = Fspath.toString target in
  debug (fun() -> Util.msg "Writing commit log: renaming %s to %s via %s\n"
    sourcename targetname tempname);
  Util.convertUnixErrorsToFatal
    "writing commit log"
    (fun () ->
       let c =
         open_out_gen [Open_wronly; Open_creat; Open_trunc; Open_excl]
           0o600 commitLogName in
       Printf.fprintf c "Warning: the last run of %s terminated abnormally "
         Uutil.myName;
       Printf.fprintf c "while moving\n   %s\nto\n   %s\nvia\n   %s\n\n"
         sourcename targetname tempname;
       Printf.fprintf c "Please check the state of these files immediately\n";
       Printf.fprintf c "(and delete this notice when you've done so).\n";
       close_out c)

let clearCommitLog () =
  debug (fun() -> (Util.msg "Deleting commit log\n"));
  Util.convertUnixErrorsToFatal
    "clearing commit log"
      (fun () -> Unix.unlink commitLogName)
    
let processCommitLog () =
  if Sys.file_exists commitLogName then begin
    raise(Util.Fatal(
          Printf.sprintf
            "Warning: the previous run of %s terminated in a dangerous state.
            Please consult the file %s, delete it, and try again."
                Uutil.myName
                commitLogName))
  end else
    Lwt.return ()
      
let processCommitLogOnHost =
  Remote.registerHostCmd "processCommitLog" processCommitLog
    
let processCommitLogs() =
  Lwt_unix.run
    (Globals.allHostsIter (fun h -> processCommitLogOnHost h ()))
    
(* ------------------------------------------------------------ *)
    
let deleteLocal (fspath, ( workingDirOpt, path)) =
  (* when the workingDirectory is set, we are dealing with a temporary file *)
  (* so we don't call the stasher in this case.                             *)
  ( match workingDirOpt with
    Some p -> 
      debug (fun () -> Util.msg  "DeleteLocal [%s] (%s, %s)\n" (Fspath.toString fspath) (Fspath.toString p) (Path.toString path));
      Os.delete p path
  | None ->
      debug (fun () -> Util.msg "DeleteLocal [%s] (None, %s)\n" (Fspath.toString fspath) (Path.toString path));
      Stasher.removeAndBackupAsAppropriate fspath path fspath path
	);
  Lwt.return ()
    
let performDelete = Remote.registerRootCmd "delete" deleteLocal
    
(* FIX: maybe we should rename the destination before making any check ? *)
let delete rootFrom pathFrom rootTo pathTo ui =
  Update.transaction (fun id ->
    Update.replaceArchive rootFrom pathFrom None Update.NoArchive id
      >>= (fun _ ->
    (*Unison do the next line cause we want to keep a backup of the file
       FIX: We only need this when we are making backups*)
	Update.updateArchive rootTo pathTo ui id >>= (fun _ ->
	  Update.replaceArchive
	    rootTo pathTo None Update.NoArchive id >>= (fun localPathTo ->
    (* Make sure the target is unchanged *)
    (* There is an unavoidable race condition here *)
	      Update.checkNoUpdates rootTo pathTo ui >>= (fun () ->
		performDelete rootTo (None, localPathTo))))))
    
(* ------------------------------------------------------------ *)
    
let setPropRemote =
  Remote.registerRootCmd
    "setProp"
    (fun (fspath, (workingDir, path, kind, newDesc)) ->
      Fileinfo.set workingDir path kind newDesc;
      Lwt.return ())
    
let setPropRemote2 =
  Remote.registerRootCmd
    "setProp2"
    (fun (fspath, (path, kind, newDesc)) ->
       let (workingDir,realPath) = Fspath.findWorkingDir fspath path in
       Fileinfo.set workingDir realPath kind newDesc;
       Lwt.return ())
    
(* FIX: we should check there has been no update before performing the
   change *)
let setProp fromRoot fromPath toRoot toPath newDesc oldDesc uiFrom uiTo =
  debug (fun() ->
    Util.msg
      "setProp %s %s %s\n   %s %s %s\n"
      (root2string fromRoot) (Path.toString fromPath)
      (Props.toString newDesc)
      (root2string toRoot) (Path.toString toPath)
      (Props.toString oldDesc));
  Update.transaction (fun id ->
    Update.updateProps fromRoot fromPath None uiFrom id >>= (fun _ ->
    (* [uiTo] provides the modtime while [desc] provides the other
       file properties *)
    Update.updateProps toRoot toPath (Some newDesc) uiTo id >>=
      (fun toLocalPath ->
	setPropRemote2 toRoot (toLocalPath, `Update oldDesc, newDesc))))
    
(* ------------------------------------------------------------ *)
    
let mkdirRemote =
  Remote.registerRootCmd
    "mkdir"
    (fun (fspath,(workingDir,path)) ->
      Os.createDir workingDir path Props.dirDefault;
      Lwt.return (Fileinfo.get false workingDir path).Fileinfo.desc)
    
let mkdir onRoot workingDir path = mkdirRemote onRoot (workingDir,path)
    
(* ------------------------------------------------------------ *)
    
let renameLocal (root, (fspath, pathFrom, pathTo)) =
  debug (fun () -> Util.msg "Renaming %s to %s in %s ; root is %s\n" 
      (Path.toString pathFrom) 
      (Path.toString pathTo) 
      (Fspath.toString fspath) 
      (Fspath.toString root));
  let localTargetPath =
    Fspath.fullLocalPath (Fspath.toString root) fspath pathTo in
  let source = Fspath.concat fspath pathFrom in
  let target = Fspath.concat fspath pathTo in
  Util.convertUnixErrorsToTransient
    (Printf.sprintf "renaming %s to %s"
       (Fspath.toString source) (Fspath.toString target))
    (fun () ->
      debugverbose (fun() ->
        Util.msg "calling Fileinfo.get from renameLocal\n");
      let filetypeFrom =
        (Fileinfo.get false source Path.empty).Fileinfo.typ in
      debugverbose (fun() ->
        Util.msg "back from Fileinfo.get from renameLocal\n");
      if filetypeFrom = `ABSENT then raise (Util.Transient (Printf.sprintf
           "Error while renaming %s to %s -- source file has disappeared!"
	   (Fspath.toString source) (Fspath.toString target)));
      let filetypeTo =
        (Fileinfo.get false target Path.empty).Fileinfo.typ in
      let source' = Fspath.toString source in (* only for debugmsg, delete? *)
      let target' = Fspath.toString target in (* only for debugmsg, delete? *)
      
       (* Windows and Unix operate differently if the target path of a
          rename already exists: in Windows an exception is raised, in
          Unix the file is clobbered.  In both Windows and Unix, if
          the target is an existing **directory**, an exception will
          be raised.  We want to avoid doing the move first, if possible,
          because this opens a "window of danger" during which the contents of
          the path is nothing. *)
      let moveFirst =
        match (filetypeFrom, filetypeTo) with
        | (_, `ABSENT)            -> false
        | ((`FILE | `SYMLINK),
           (`FILE | `SYMLINK))    -> Util.osType <> `Unix
        | _                       -> true (* Safe default *)
      in
      if moveFirst then begin
        let tmpPath = Os.tempPath fspath pathTo in
        let temp = Fspath.concat fspath tmpPath in
        let temp' = Fspath.toString temp in
        writeCommitLog source target temp';

        debug (fun() -> Util.msg "moving %s to %s\n" target' temp');
        match Os.renameIfAllowed target Path.empty temp Path.empty with
          None ->  
            (* If the renaming fails, we will be left with
               DANGER.README file which will make any other
               (similar) renaming fail in a cryptic way.  So, it
               seems better to abort early. *)
            Util.convertUnixErrorsToFatal "renaming with commit log"
              (fun () ->
                debug (fun() -> Util.msg "rename %s to %s\n" source' target');
                Os.rename source Path.empty target Path.empty;
                Stasher.stashCurrentVersion localTargetPath;
                Stasher.removeAndBackupAsAppropriate temp Path.empty root localTargetPath;
                clearCommitLog())
        | Some e ->
            (* We are not able to move the file.  We clear the commit
               log as nothing happened, then fail. *)
            clearCommitLog();
            Util.convertUnixErrorsToTransient "renaming" (fun () -> raise e)
      end else begin
        debugverbose (fun() -> Util.msg "rename: moveFirst=false\n");
        Stasher.removeAndBackupAsAppropriate root localTargetPath root localTargetPath;
        Os.rename source Path.empty target Path.empty;
        Stasher.stashCurrentVersion localTargetPath
      end;
      Lwt.return ())
    
let renameOnHost = Remote.registerRootCmd "rename" renameLocal
    
(* FIX: maybe we should rename the destination before making any check ? *)
(* FIX: When this code was originally written, we assumed that the
   checkNoUpdates would happen immediately before the renameOnHost, so that
   the window of danger where other processes could invalidate the thing we
   just checked was very small.  But now that transport is multi-threaded,
   this window of danger could get very long because other transfers are
   saturating the link.  It would be better, I think, to introduce a real
   2PC protocol here, so that both sides would (locally and almost-atomically)
   check that their assumptions had not been violated and then switch the
   temp file into place, but remain able to roll back if something fails
   either locally or on the other side. *)
let rename root pathInArchive workingDir pathOld pathNew ui =
  debug (fun() ->
    Util.msg "rename(root=%s, pathOld=%s, pathNew=%s)\n"
      (root2string root)
      (Path.toString pathOld) (Path.toString pathNew));
  (* Make sure the target is unchanged, then do the rename.
     (Note that there is an unavoidable race condition here...) *)
  Update.checkNoUpdates root pathInArchive ui >>= (fun () ->
    renameOnHost root (workingDir, pathOld, pathNew))

(* ------------------------------------------------------------ *)

let checkContentsChangeLocal
      currfspath path archDesc archDig archStamp archRess =
  let info = Fileinfo.get true currfspath path in
  match archStamp with
    Fileinfo.InodeStamp inode
    when info.Fileinfo.inode = inode
        && Props.same_time info.Fileinfo.desc archDesc ->
	  if Props.length archDesc <> Props.length info.Fileinfo.desc then
	    raise (Util.Transient (Printf.sprintf
              "The file %s\nhas been modified during synchronization: transfer aborted.%s"
              (Fspath.concatToString currfspath path)
              (if Util.osType = `Win32 && (Prefs.read Update.fastcheck)="yes" then
                ("If this happens repeatedly, try running once with the "
                 ^ "fastcheck option set to 'no'.")
              else "")))
  | _ ->
      (* Note that we fall back to the paranoid check (using a fingerprint)
         even if a CtimeStamp was provided, since we do not trust them
         completely. *)
      let info = Fileinfo.get true currfspath path in
      let (info, newDig) = Os.safeFingerprint currfspath path info None in
      if archDig <> newDig then
        raise (Util.Transient (Printf.sprintf
          "The file %s\nhas been modified during synchronization: transfer aborted"
          (Fspath.concatToString currfspath path)))

let checkContentsChangeOnHost =
  Remote.registerRootCmd
    "checkContentsChange"
    (fun (currfspath, (path, archDesc, archDig, archStamp, archRess)) ->
      checkContentsChangeLocal
        currfspath path archDesc archDig archStamp archRess;
      Lwt.return ())
    
let checkContentsChange root path archDesc archDig archStamp archRess =
  checkContentsChangeOnHost root (path, archDesc, archDig, archStamp, archRess)

(* ------------------------------------------------------------ *)

(* Calculate the target working directory and paths for the copy.
      workingDir  is an fspath naming the directory on the target
                  host where the copied file will actually live.
                  (In the case where pathTo names a symbolic link, this
                  will be the parent directory of the file that the
                  symlink points to, not the symlink itself.  Note that
                  this fspath may be outside of the replica, or even
                  on a different volume.)
      realPathTo  is the name of the target file relative to workingDir.
                  (If pathTo names a symlink, this will be the name of
                  the file pointed to by the symlink, not the name of the
                  link itself.)
      tempPathTo  is a temporary file name in the workingDir.  The file (or
                  directory structure) will first be copied here, then
                  "almost atomically" moved onto realPathTo. *)

let setupTargetPathsLocal (fspath, path) =
  let localPath = Update.translatePathLocal fspath path in
  let (workingDir,realPath) = Fspath.findWorkingDir fspath localPath in
  let tempPath = Os.tempPath workingDir realPath in
  Lwt.return (workingDir, realPath, tempPath, localPath)

let setupTargetPaths =
  Remote.registerRootCmd "setupTargetPaths" setupTargetPathsLocal

(* ------------------------------------------------------------ *)

let makeSymlink =
  Remote.registerRootCmd
    "makeSymlink"
    (fun (fspath, (workingDir, path, l)) ->
       Os.symlink workingDir path l;
       Lwt.return ())

let copyReg = Lwt_util.make_region 50

let copy
      update
      rootFrom pathFrom   (* copy from here... *)
      uiFrom              (* (and then check that this updateItem still
                             describes the current state of the src replica) *)
      rootTo pathTo       (* ...to here *)
      uiTo                (* (but, before committing the copy, check that
                             this updateItem still describes the current
                             state of the target replica) *)
      id =                (* for progress display *)
  debug (fun() ->
    Util.msg
      "copy %s %s ---> %s %s \n"
      (root2string rootFrom) (Path.toString pathFrom)
      (root2string rootTo) (Path.toString pathTo));
  (* Calculate target paths *)
  setupTargetPaths rootTo pathTo
     >>= (fun (workingDir, realPathTo, tempPathTo, _) ->
  (* Inner loop for recursive copy... *)
  let rec copyRec pFrom      (* Path to copy from *)
                  pTo        (* (Temp) path to copy to *)
                  realPTo    (* Path where this file will ultimately be placed
                                (needed by rsync, which uses the old contents
                                of this file to optimize transfer) *)
                  f =        (* Source archive subtree for this path *)
    debug (fun() ->
      Util.msg "copyRec %s --> %s  (really to %s)\n"
        (Path.toString pFrom) (Path.toString pTo)
        (Path.toString realPTo));
    match f with
      Update.ArchiveFile (desc, dig, stamp, ress) ->
        Lwt_util.run_in_region copyReg 1 (fun () ->
          Abort.check id;
          Copy.file
            rootFrom pFrom rootTo workingDir pTo realPTo
            update desc dig ress id
            >>= (fun () ->
          checkContentsChange rootFrom pFrom desc dig stamp ress))
    | Update.ArchiveSymlink l ->
        Lwt_util.run_in_region copyReg 1 (fun () ->
          debug (fun() -> Util.msg "Making symlink %s/%s -> %s\n"
                            (root2string rootTo) (Path.toString pTo) l);
          Abort.check id;
          makeSymlink rootTo (workingDir, pTo, l))
    | Update.ArchiveDir (desc, children) ->
        Lwt_util.run_in_region copyReg 1 (fun () ->
          debug (fun() -> Util.msg "Creating directory %s/%s\n"
            (root2string rootTo) (Path.toString pTo));
          mkdir rootTo workingDir pTo) >>= (fun initialDesc ->
        Abort.check id;
        let actions =
          Update.NameMap.fold
            (fun name child rem ->
               copyRec (Path.child pFrom name)
                       (Path.child pTo name)
                       (Path.child realPTo name)
                       child
               :: rem)
            children []
        in
        Lwt.catch
          (fun () -> Lwt_util.join actions)
          (fun e ->
             (* If one thread fails (in a non-fatal way), we wait for
                all other threads to terminate before continuing *)
             Abort.file id;
             match e with
               Util.Transient _ ->
                 let e = ref e in
                 Lwt_util.iter
                   (fun act ->
                      Lwt.catch
                         (fun () -> act)
                         (fun e' ->
                            match e' with
                              Util.Transient _ ->
                                if Abort.testException !e then e := e';
                                Lwt.return ()
                            | _                ->
                                Lwt.fail e'))
                   actions >>= (fun () ->
                 Lwt.fail !e)
             | _ ->
                 Lwt.fail e) >>= (fun () ->
        Lwt_util.run_in_region copyReg 1 (fun () ->
          (* We use the actual file permissions so as to preserve
             inherited bits *)
          Abort.check id;
          setPropRemote rootTo
            (workingDir, pTo, `Set initialDesc, desc))))
    | Update.NoArchive ->
        assert false
  in
  Remote.Thread.unwindProtect
    (fun () ->
       Update.transaction (fun id ->
         (* Update the archive on the source replica (but don't commit
            the changes yet) and return the part of the new archive
            corresponding to this path *)
         Update.updateArchive rootFrom pathFrom uiFrom id
           >>= (fun (localPathFrom, archFrom) ->
         let make_backup =
           (* Perform (asynchronously) a backup of the destination files *)
           Update.updateArchive rootTo pathTo uiTo id
         in
         copyRec localPathFrom tempPathTo realPathTo archFrom >>= (fun () ->
         make_backup >>= (fun _ ->
         Update.replaceArchive
           rootTo pathTo (Some (workingDir, tempPathTo))
           archFrom id >>= (fun _ ->
             rename rootTo pathTo workingDir tempPathTo realPathTo uiTo ))))))
    (fun _ ->
       performDelete rootTo (Some workingDir, tempPathTo)))

(* ------------------------------------------------------------ *)

let readChannelTillEof c =
  let rec loop lines =
    try let l = input_line c in
        loop (l::lines)
    with End_of_file -> lines in
  String.concat "\n" (Safelist.rev (loop []))

let diffCmd =
  Prefs.createString "diff" "diff -u"
    "*command for showing differences between files"
    ("This preference can be used to control the name and command-line "
     ^ "arguments of the system "
     ^ "utility used to generate displays of file differences.  The default "
     ^ "is `\\verb|diff -u|'.  If the value of this preference contains the substrings "
     ^ "CURRENT1 and CURRENT2, these will be replaced by the names of the files to be "
     ^ "diffed.  If not, the two filenames will be appended to the command.  In both "
     ^ "cases, the filenames are suitably quoted.")

(* Using single quotes is simpler under Unix but they are not accepted
   by the Windows shell.  Double quotes without further quoting is
   sufficient with Windows as filenames are not allowed to contain
   double quotes. *)
let quotes s =
  if Util.osType = `Win32 && not Util.isCygwin then
    "\"" ^ s ^ "\""
  else
    "'" ^ Util.replacesubstring s "'" "'\''" ^ "'"

let rec diff root1 path1 ui1 root2 path2 ui2 showDiff id =
  debug (fun () ->
    Util.msg
      "diff %s %s %s %s ...\n"
      (root2string root1) (Path.toString path1)
      (root2string root2) (Path.toString path2));
  let displayDiff fspath1 fspath2 =
    let cmd =
      if Util.findsubstring "CURRENT1" (Prefs.read diffCmd) = None then
          (Prefs.read diffCmd)
        ^ " " ^ (quotes (Fspath.toString fspath1))
        ^ " " ^ (quotes (Fspath.toString fspath2))
      else
        Util.replacesubstrings (Prefs.read diffCmd)
          ["CURRENT1", quotes (Fspath.toString fspath1);
           "CURRENT2", quotes (Fspath.toString fspath2)] in
    let c = Unix.open_process_in cmd in
    showDiff cmd (readChannelTillEof c);
    ignore(Unix.close_process_in c) in
  let (desc1, fp1, ress1, desc2, fp2, ress2) = Common.fileInfos ui1 ui2 in
  match root1,root2 with
    (Local,fspath1),(Local,fspath2) ->
      Util.convertUnixErrorsToTransient
        "diffing files"
        (fun () ->
           let path1 = Update.translatePathLocal fspath1 path1 in
           let path2 = Update.translatePathLocal fspath2 path2 in
           displayDiff
             (Fspath.concat fspath1 path1) (Fspath.concat fspath2 path2))
  | (Local,fspath1),(Remote host2,fspath2) ->
      Util.convertUnixErrorsToTransient
        "diffing files"
        (fun () ->
           let path1 = Update.translatePathLocal fspath1 path1 in
           let (workingDir, realPath) = Fspath.findWorkingDir fspath1 path1 in
           let tmppath =
             Path.addSuffixToFinalName realPath "#unisondiff-" in
           Os.delete workingDir tmppath;
           Lwt_unix.run
             (Update.translatePath root2 path2 >>= (fun path2 ->
              Copy.file root2 path2 root1 workingDir tmppath realPath
                `Copy (Props.setLength Props.fileSafe (Props.length desc2))
                 fp2 ress2 id));
           displayDiff
	     (Fspath.concat workingDir realPath)
             (Fspath.concat workingDir tmppath);
           Os.delete workingDir tmppath)
  | (Remote host1,fspath1),(Local,fspath2) ->
      Util.convertUnixErrorsToTransient
        "diffing files"
        (fun () ->
           let path2 = Update.translatePathLocal fspath2 path2 in
           let (workingDir, realPath) = Fspath.findWorkingDir fspath2 path2 in
           let tmppath =
             Path.addSuffixToFinalName realPath "#unisondiff-" in
           Lwt_unix.run
             (Update.translatePath root1 path1 >>= (fun path1 ->
              (* Note that we don't need the resource fork *)
              Copy.file root1 path1 root2 workingDir tmppath realPath
                `Copy (Props.setLength Props.fileSafe (Props.length desc1))
                 fp1 ress1 id));
           displayDiff
             (Fspath.concat workingDir tmppath)
	     (Fspath.concat workingDir realPath);
           Os.delete workingDir tmppath)
  | (Remote host1,fspath1),(Remote host2,fspath2) ->
      assert false


(**********************************************************************)

(* Taken from ocamltk/jpf/fileselect.ml *)
let get_files_in_directory dir =
  let dirh = Fspath.opendir (Fspath.canonize (Some dir)) in
  let files = ref [] in
  begin try
    while true do files := Unix.readdir dirh :: !files done
  with End_of_file ->
    Unix.closedir dirh
  end;
  Sort.list (<) !files

let ls dir pattern =
  Util.convertUnixErrorsToTransient
    "listing files"
    (fun () ->
       let files = get_files_in_directory dir in
       let re = Rx.glob pattern in
       let rec filter l =
         match l with
           [] ->
             []
         | hd :: tl ->
             if Rx.match_string re hd then hd :: filter tl else filter tl
       in
       filter files)


(***********************************************************************
                  CALL OUT TO EXTERNAL MERGE PROGRAM
************************************************************************)

let readChannelTillEof_lwt c =
  let rec loop lines =
    let lo =
      try
        Some(Lwt_unix.run (Lwt_unix.input_line c))
      with End_of_file -> None
    in
    match lo with
      Some l -> loop (l :: lines)
    | None   -> lines
  in
  String.concat "\n" (Safelist.rev (loop []))

let formatMergeCmd p f1 f2 backup out1 out2 outarch =
  if not (Globals.shouldMerge p) then
    raise (Util.Transient ("'merge' preference not set for "^(Path.toString p)));
  let raw =
    try Globals.mergeCmdForPath p
    with Not_found ->
      raise (Util.Transient ("'merge' preference does not provide a command "
                             ^ "template for " ^ (Path.toString p)))
  in
  let cooked = raw in
  let cooked = Util.replacesubstring cooked "CURRENT1" f1 in
  let cooked = Util.replacesubstring cooked "CURRENT2" f2 in
  let cooked =
    match backup with
      None -> begin
	let cooked = Util.replacesubstring cooked "CURRENTARCHOPT" " " in
	match Util.findsubstring "CURRENTARCH" cooked with
	  None -> cooked
	| Some _ -> raise (Util.Transient ("No archive found whereas the "^
					   "'merge' command template expects one"))
      end
    | Some(s) ->
	let cooked = Util.replacesubstring cooked "CURRENTARCHOPT" s in
	let cooked = Util.replacesubstring cooked "CURRENTARCH"    s in
        cooked in
  let cooked = Util.replacesubstring cooked "NEW1"     out1 in
  let cooked = Util.replacesubstring cooked "NEW2"     out2 in
  let cooked = Util.replacesubstring cooked "NEWARCH"  outarch in
  let cooked = Util.replacesubstring cooked "NEW" out1 in
  let cooked = Util.replacesubstring cooked "PATH" (Path.toString p) in
  cooked
    
let copyBack fspathFrom pathFrom rootTo pathTo propsTo uiTo id =
  setupTargetPaths rootTo pathTo
    >>= (fun (workingDirForCopy, realPathTo, tempPathTo, localPathTo) ->
  let info = Fileinfo.get false fspathFrom pathFrom in
  let fp = Os.fingerprint fspathFrom pathFrom info in
  let stamp = Osx.stamp info.Fileinfo.osX in
  let newprops = Props.setLength propsTo (Props.length info.Fileinfo.desc) in
  Copy.file
    (Local, fspathFrom) pathFrom rootTo workingDirForCopy tempPathTo realPathTo
    `Copy newprops fp stamp id >>= (fun () ->
      rename rootTo pathTo workingDirForCopy tempPathTo realPathTo
        uiTo ))
    
let merge root1 root2 path id ui1 ui2 showMergeFn =
  debug (fun () -> Util.msg "merge path %s between roots %s and %s\n"
      (Path.toString path) (root2string root1) (root2string root2));
  let (localPath1, (workingDirForMerge, basep)) =
    match root1 with
      (Local,fspath1) ->
        let localPath1 = Update.translatePathLocal fspath1 path in
        (localPath1, Fspath.findWorkingDir fspath1 localPath1)
    | _ -> assert false (* roots are sorted: first root is always local *)
           (* FIX: I (JV) believe this assumption is wrong: roots are not sorted... *)
           (* Sigh.  Fixing this will require some restructuring of the following... *) in
  
  (* We're going to be doing a lot of copying, so let's define a shorthand
     that fixes most of the arguments to Copy.localfile *)
  let copy l =
    Safelist.iter
      (fun (src,trg) ->
        Os.delete workingDirForMerge trg;
        let info = Fileinfo.get false workingDirForMerge src in
        Copy.localFile
          workingDirForMerge src
          workingDirForMerge trg trg
          `Copy info.Fileinfo.desc
          (Osx.ressLength info.Fileinfo.osX.Osx.ressInfo) (Some id))
      l in
  
  (* These names should be automatically ignored!  And probably we should use
     names that will be recognized as temp by ordinary Unix programs -- e.g.,
     beginning with dot.  Perhaps the update detection sweep should remove them
     automatically.  *)
  let working1 = Path.addPrefixToFinalName basep ".#unisonmerge1-" in
  let working2 = Path.addPrefixToFinalName basep ".#unisonmerge2-" in
  let workingarch = Path.addPrefixToFinalName basep ".#unisonmergearch-" in
  let new1 = Path.addPrefixToFinalName basep ".#unisonmergenew1-" in
  let new2 = Path.addPrefixToFinalName basep ".#unisonmergenew2-" in
  let newarch = Path.addPrefixToFinalName basep ".#unisonmergenewarch-" in
  
  let (desc1, fp1, ress1, desc2, fp2, ress2) = Common.fileInfos ui1 ui2 in
  
  Util.convertUnixErrorsToTransient "merging files" (fun () ->
    (* Install finalizer (see below) in case we unwind the stack *)
    Util.finalize (fun () ->
      
    (* Make local copies of the two replicas *)
      Os.delete workingDirForMerge working1;
      Os.delete workingDirForMerge working2;
      Lwt_unix.run
	(Copy.file
           root1 localPath1 root1 workingDirForMerge working1 basep
           `Copy desc1 fp1 ress1 id);
      Lwt_unix.run
	(Update.translatePath root2 path >>= (fun path ->
	  Copy.file
	    root2 path root1 workingDirForMerge working2 basep
	    `Copy desc2 fp2 ress2 id));
      
      (* retrieve the archive for this file, if any *)
      let arch =
	match ui1, ui2 with
	| Updates (_, Previous (_,_,dig,_)), Updates (_, Previous (_,_,dig2,_)) ->
	    if dig = dig2 then
	      Stasher.getRecentVersion workingDirForMerge localPath1 dig 
	    else
	      assert false
	| NoUpdates, Updates(_, Previous (_,_,dig,_))
	| Updates(_, Previous (_,_,dig,_)), NoUpdates -> 
	    Stasher.getRecentVersion workingDirForMerge localPath1 dig
	| Updates (_, New), Updates(_, New) 
	| Updates (_, New), NoUpdates
	| NoUpdates, Updates (_, New) ->
	    None
	| _ -> assert false

      in
      
      (* make a local copy of the archive file (in case the merge program  
         overwrites it and the program crashes before the call to the Stasher) *)
      let _= 
	match arch with 
	  Some fspath ->
	    let tmpPath = Path.addPrefixToFinalName basep ".#unisonarchbackup-" in
	    let info = Fileinfo.get false fspath Path.empty in
	    Copy.localFile 
	      fspath Path.empty 
	      workingDirForMerge tmpPath tmpPath
	      `Copy 
	      info.Fileinfo.desc
	      (Osx.ressLength info.Fileinfo.osX.Osx.ressInfo)
	      None 
	| None ->
	    ()      in
      
      (* run the merge command *)
      Os.delete workingDirForMerge new1;
      Os.delete workingDirForMerge new2;
      Os.delete workingDirForMerge newarch;
      let info1 = Fileinfo.get false workingDirForMerge working1 in
      (* FIX: Why split out the parts of the pair?  Why is it not abstract anyway??? *)
      let dig1 = Os.fingerprint workingDirForMerge working1 info1 in
      let info2 = Fileinfo.get false workingDirForMerge working2 in
      let dig2 = Os.fingerprint workingDirForMerge working2 info2 in
      let cmd = formatMergeCmd
          path
          (Fspath.concatToString workingDirForMerge working1)
          (Fspath.concatToString workingDirForMerge working2)
          (match arch with 
	    None -> None 
	  | Some f -> Some(Fspath.toString f))
          (Fspath.concatToString workingDirForMerge new1)
          (Fspath.concatToString workingDirForMerge new2)
          (Fspath.concatToString workingDirForMerge newarch) in
      Trace.log (Printf.sprintf "%s\n" cmd);
      
      let c = Unix.open_process_in cmd in
      let mergeLog = readChannelTillEof c in
      let returnValue = Unix.close_process_in c in

      (* check what the merge command did *)
      if returnValue <> Unix.WEXITED 0 then
        raise (Util.Transient "Merge program exited with non-zero status");

      let mergeText =
        cmd ^ "\n" ^ 
        (if mergeLog="" then "Merge program exited normally"
        else mergeLog) in

      if not
        (showMergeFn
           (Printf.sprintf "Results of merging %s" (Path.toString path))
           mergeText) then
          raise (Util.Transient "User cancelled merge");

      (* Check which files got created by the merge command and do something appropriate
         with them *)
        let new1exists = Sys.file_exists (Fspath.concatToString workingDirForMerge new1) in
        let new2exists = Sys.file_exists (Fspath.concatToString workingDirForMerge new2) in
        let newarchexists = Sys.file_exists (Fspath.concatToString workingDirForMerge newarch) in

      if new1exists && new2exists && newarchexists then begin
        debug (fun () -> Util.msg "Three outputs detected \n");
        copy [(new1,working1); (new2, working2); (newarch, workingarch)];
      end

      else if new1exists && new2exists && (not newarchexists) then begin
        debug (fun () -> Util.msg "Two outputs detected \n");
        copy [(new1,working1); (new2,working2)];
        let info1 = Fileinfo.get false workingDirForMerge new1 in
        let info2 = Fileinfo.get false workingDirForMerge new2 in
        let dig1' = Os.fingerprint workingDirForMerge new1 info1 in
        let dig2' = Os.fingerprint workingDirForMerge new2 info2 in
        if dig1'=dig2' then begin
          debug (fun () -> Util.msg "Two outputs equal => update the archive\n");
          copy [(new1,workingarch)];
        end
      end

      else if new1exists && (not new2exists) && (not newarchexists) then begin
        debug (fun () -> Util.msg "One output detected \n");
        copy [(new1,working1); (new1,working2); (new1,workingarch)];
      end

      else if (not new1exists) && new2exists && (not newarchexists) then begin
        assert false
      end

      else if (not new1exists) && (not new2exists) && (not newarchexists) then begin
        debug (fun () -> Util.msg "No outputs detected \n");
        let working1_still_exists = Sys.file_exists (Fspath.concatToString workingDirForMerge working1) in
        let working2_still_exists = Sys.file_exists (Fspath.concatToString workingDirForMerge working2) in

        if working1_still_exists && working2_still_exists then begin
          debug (fun () -> Util.msg "No output from merge cmd and both original files are still present\n");
          let info1' = Fileinfo.get false workingDirForMerge working1 in
          let dig1' = Os.fingerprint workingDirForMerge working1 info1' in
          let info2' = Fileinfo.get false workingDirForMerge working2 in
          let dig2' = Os.fingerprint workingDirForMerge working2 info2' in
          if dig1 = dig1' && dig2 = dig2' then
            raise (Util.Transient "Merge program didn't change either temp file");
          if dig1' = dig2' then begin
            debug (fun () -> Util.msg "Merge program made files equal\n");
            copy [(working1,workingarch)];
          end else if dig2 = dig2' then begin
            debug (fun () -> Util.msg "Merge program changed just first input\n");
            copy [(working1,working2);(working1,workingarch)]
          end else if dig1 = dig1' then begin
            debug (fun () -> Util.msg "Merge program changed just second input\n");
            copy [(working2,working1);(working2,workingarch)]
          end else
            raise (Util.Transient ("Error: the merge function changed both of "
                                   ^ "its inputs but did not make them equal"))
        end

        else if working1_still_exists && (not working2_still_exists) then begin
          debug (fun () -> Util.msg "No outputs and second replica has been deleted \n");
          copy [(working1,working2); (working1,workingarch)];
        end

        else if (not working1_still_exists) && working2_still_exists then begin
          debug (fun () -> Util.msg "No outputs and first replica has been deleted \n");
          copy [(working2,working1); (working2,workingarch)];
        end

        else
          raise (Util.Transient ("Error: the merge function deleted both of its "
                                 ^ "inputs and generated no output!"))
      end;
      
      Lwt_unix.run
	(debug (fun () -> Util.msg "Committing results of merge\n");
         copyBack workingDirForMerge working1 root1 path desc1 ui1 id >>= (fun () ->
         copyBack workingDirForMerge working2 root2 path desc2 ui2 id >>= (fun () ->
           let arch_fspath = Fspath.concat workingDirForMerge workingarch in
           if (Sys.file_exists (Fspath.toString arch_fspath)) then begin
               (* Update the unison archives to reflect the new external archive file *)
             debug (fun () -> Util.msg "Updating unison archives to reflect results of merge\n");
             let infoarch = Fileinfo.get false workingDirForMerge workingarch in
             let new_archive_entry =
               Update.ArchiveFile
                 (Props.get (Fspath.stat arch_fspath) infoarch.osX,
                  Os.fingerprint arch_fspath Path.empty infoarch,
                  Fileinfo.stamp (Fileinfo.get true arch_fspath Path.empty),
                  Osx.stamp infoarch.osX) in
             Update.transaction
               (fun transid ->
                 Update.replaceArchive root1 path
                   (Some(workingDirForMerge, workingarch))
                   new_archive_entry transid >>= (fun _ ->
                     Update.replaceArchive root2 path
                       (Some(workingDirForMerge, workingarch))
                       new_archive_entry transid >>= (fun _ ->
                         Lwt.return ())))
           end else 
             (Lwt.return ()) )))))
    (fun _ ->
      Util.ignoreTransientErrors
	(fun () ->
          Os.delete workingDirForMerge working1;
          Os.delete workingDirForMerge working2;
          Os.delete workingDirForMerge workingarch;
          Os.delete workingDirForMerge new1;
          Os.delete workingDirForMerge new2;
          Os.delete workingDirForMerge newarch
	    ))
    
