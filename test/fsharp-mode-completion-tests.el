(require 'test-common)

;;; Jump to defn

(defconst finddeclstr1
  (let ((file (concat fs-file-dir "Program.fs")))
    (format "{\"Kind\":\"finddecl\",\"Data\":{\"File\":\"%s\",\"Line\":2,\"Column\":7}}\n" file))
  "A message for jumping to a definition in the same file")

(defconst finddeclstr2
  (let ((file (concat fs-file-dir "FileTwo.fs")))
    (format "{\"Kind\":\"finddecl\",\"Data\":{\"File\":\"%s\",\"Line\":13,\"Column\":12}}\n" file file))
    "A message for jumping to a definition in another file")

(check "jumping to local definition should not change buffer"
  (let ((f (file-truename (concat fs-file-dir "Program.fs"))))
    (stubbing-process-functions
     (using-file f
                 (fsharp-ac-filter-output nil finddeclstr1)
                 (should (equal f (buffer-file-name)))))))

(check "jumping to local definition should move point to definition"
  (stubbing-process-functions
   (using-file (concat fs-file-dir "Program.fs")
               (fsharp-ac-filter-output nil finddeclstr1)
               (should (equal (point) 18)))))

(check "jumping to definition in another file should open that file"
  (let ((f1 (concat fs-file-dir "Program.fs"))
        (f2 (file-truename (concat fs-file-dir "FileTwo.fs"))))
      (stubbing-process-functions
       (using-file f1
         (fsharp-ac-filter-output nil finddeclstr2)
         (should (equal (buffer-file-name) f2))))))

(check "jumping to definition in another file should move point to definition"
    (stubbing-process-functions
     (using-file (concat fs-file-dir "Program.fs")
       (fsharp-ac-filter-output nil finddeclstr2)
       (should (equal (point) 127)))))

;;; Error parsing

(defconst err-brace-str
  "{\"Kind\":\"errors\",\"Data\":[{\"FileName\":\"<filename>\",\"StartLine\":10,\"EndLine\":10,\"StartColumn\":1,\"EndColumn\":4,\"Severity\":\"Warning\",\"Message\":\"Possible incorrect indentation: this token is offside of context started at position (8:1). Try indenting this token further or using standard formatting conventions.\",\"Subcategory\":\"parse\"},{\"FileName\":\"<filename>\",\"StartLine\":12,\"EndLine\":12,\"StartColumn\":1,\"EndColumn\":3,\"Severity\":\"Warning\",\"Message\":\"Possible incorrect indentation: this token is offside of context started at position (8:1). Try indenting this token further or using standard formatting conventions.\",\"Subcategory\":\"parse\"},{\"FileName\":\"<filename>\",\"StartLine\":12,\"EndLine\":12,\"StartColumn\":1,\"EndColumn\":3,\"Severity\":\"Error\",\"Message\":\"Unexpected symbol '[<' in expression\",\"Subcategory\":\"parse\"}]}\n"
  "A list of errors containing a square bracket to check the parsing")

(check "parses errors from given string"
  (stubbing-process-functions
   (using-file
    (concat fs-file-dir "Program.fs")
    (let* ((json-array-type 'list)
           (json-object-type 'hash-table)
           (json-key-type 'string)
           n
           (flycheck-fsharp--error-callback-info (cons 'checker (lambda (_ result)
                                                                 (setq n (length result))))))
      (flycheck-fsharp-handle-errors (gethash "Data" (json-read-from-string err-brace-str)))
      (should (eq n 3))))))

(defmacro check-filter (desc &rest body)
  "Test properties of filtered output from the ac-process."
  (declare (indent 1))
  `(check ,desc
     (using-file "*fsharp-complete*"
       (stubbing-process-functions
        (let* ((file (concat fs-file-dir "Program.fs"))
               (errmsg (s-replace "<filename>" file err-brace-str)))
          (find-file file)
          (fsharp-ac-filter-output nil errmsg))
       ,@body))))

(check-filter "error clears partial data"
  (should (equal "" (with-current-buffer (process-buffer
                                          (fsharp-ac-completion-process nil))
                      (buffer-string)))))

(check-filter "errors cause overlays to be drawn"
  (should (equal (->> (flycheck-count-errors flycheck-current-errors)
                      (mapcar 'cdr)
                      (apply '+))
                 3)))

(check-filter "error overlay has expected text"
    (flycheck-next-error)
    (should (equal (flycheck-error-message (car-safe (flycheck-overlay-errors-at (point))))
                   (concat "Possible incorrect indentation: "
                           "this token is offside of context started at "
                           "position (8:1). "
                           "Try indenting this token further or using standard "
                           "formatting conventions."))))

(check-filter "first overlay should have the warning face"
  (flycheck-next-error)
  (should (eq 'warning (flycheck-error-level (car-safe (flycheck-overlay-errors-at (point)))))))

(check-filter "third overlay should have the error face"
  (flycheck-next-error 2)
  (should (eq 'error (flycheck-error-level (car-safe (flycheck-overlay-errors-at (point)))))))

;;; Loading projects

(defmacro check-project-loading (desc exists &rest body)
  "Test fixture for loading projects, stubbing process-related functions."
  (declare (indent 2))
  `(check ,(concat "check project loading " desc)
     (stubbing-process-functions
      (noflet ((fsharp-ac/start-process ())
               (file-exists-p (_) ,exists))
        ,@body))))

(check-project-loading "returns nil if not fsproj"
    'exists
  (should-not (fsharp-ac/load-project "foo")))

(check-project-loading "returns nil if the given fsproj does not exist"
    nil ; doesn't exist
  (should-not (fsharp-ac/load-project "foo")))

(check-project-loading "returns the project path if loading succeeded"
    'exists
  (should-match "foo.fsproj" (fsharp-ac/load-project "foo.fsproj")))

;;; Process handling

(defmacro check-handler (desc &rest body)
  "Test fixture for process handler tests.
Stubs out functions that call on the ac process."
  (declare (indent 1))
  `(check ,(concat "process handler " desc)
     (setq major-mode 'fsharp-mode)
     (stubbing-process-functions
      (noflet ((fsharp-ac-can-make-request (&optional _) t)
               (file-truename (x &rest _) x))
         ,@body))))

(defmacro stub-fn (sym var &rest body)
  "Stub the given unary function, with the argument to the
function bound to VAR in BODY. "
  (declare (indent 2))
  `(let (,var)
     (noflet ((,sym (x &rest xs) (setq ,var x)))
       ,@body)))

(check-handler "prints message on error"
  (stub-fn message err
    (fsharp-ac-filter-output nil "{\"Kind\": \"error\", \"Data\": \"foo\"}\n")
    (should-match "foo" err)))

;;; Tooltips and typesigs

(defconst tooltip-msg
  "{\"Kind\": \"tooltip\", \"Data\": [[{ \"Signature\": \"foo\", \"Comment\": \"\" }]] }\n"
  "A simple tooltip message")

(check-handler "uses popup in terminal if tooltip is requested"
  (let ((fsharp-ac-use-popup t))
    (noflet ((display-graphic-p () nil))
      (stub-fn popup-tip tip
        (fsharp-ac/show-tooltip-at-point)
        (fsharp-ac-filter-output nil tooltip-msg)
        (should-match "foo" tip)))))

(check-handler "uses pos-tip in GUI if tooltip is requested"
  (let ((fsharp-ac-use-popup t))
    (noflet ((display-graphic-p () t))
      (stub-fn pos-tip-show tip
        (fsharp-ac/show-tooltip-at-point)
        (fsharp-ac-filter-output nil tooltip-msg)
        (should-match "foo" tip)))))

(check-handler "does not show popup if use-popup is nil"
  (let ((fsharp-ac-use-popup nil))
    (stub-fn popup-tip called
      (fsharp-ac/show-tooltip-at-point)
      (fsharp-ac-filter-output nil tooltip-msg)
      (should-not called))))

(check-handler "displays tooltip in info window if use-popup is nil"
  (let ((fsharp-ac-use-popup nil))
    ;; HACK: stub internals of with-help-window.
    ;; with-help-window is a macro and macrolet and labels don't seem to work.
    (stub-fn help-window-setup win
      (fsharp-ac/show-tooltip-at-point)
      (fsharp-ac-filter-output nil tooltip-msg)
      (should-match "fsharp info" (buffer-name (window-buffer win))))))

(defconst typesig-msg
  "{\"Kind\": \"typesig\", \"Data\": \"foo\" }\n"
  "A simple tooltip message")

(check-handler "displays typesig in minibuffer if typesig is requested"
  (noflet ((message (fmt &rest args) (setq sig (apply 'format fmt args))))
    (fsharp-ac/show-typesig-at-point)
    (fsharp-ac-filter-output nil typesig-msg)
    (should= "foo" sig)))

;;; Residue computation

(defmacro check-residue (desc line res)
  `(check ,desc
     (with-temp-buffer
       (insert ,line)
       (should= ,res (buffer-substring-no-properties (fsharp-ac--residue) (buffer-end 1))))))

(check-residue "standard residue" "System.Console.WriteL" "WriteL")
(check-residue "standard residue, previous raw identifier" "System.``Hello Console``.WriteL" "WriteL")
(check-residue "raw residue, standard previous" "System.Console.``Writ eL" "``Writ eL")
(check-residue "raw residue, raw previous" "System.``Hello Console``.``Wr$ it.eL" "``Wr$ it.eL")
(check-residue "raw residue, trailing dot" "System.Console.``WriteL." "``WriteL.")

;;; Warnings when intellisense requests made without bg process

(check "no error message in a script if bg process running"
 (stubbing-process-functions
  (stub-fn message msg
   (using-temp-file "test.fsx"
    (fsharp-ac-can-make-request)
    (should (null msg))))))

(check "error message in a script if no bg process running"
 (stubbing-process-functions
  (stub-fn message msg
   (noflet ((fsharp-ac--process-live-p (host)))
     (using-temp-file "test.fsx"
       (fsharp-ac-can-make-request)
       (should-match "not running" msg))))))

(check "no error message in a script if no bg process running and quiet mode selected"
 (stubbing-process-functions
  (stub-fn message msg
   (noflet ((fsharp-ac--process-live-p (host)))
     (using-temp-file "test.fsx"
       (fsharp-ac-can-make-request t)
       (should (null msg)))))))

(check "no error message if project file loaded"
  (let ((f (concat fs-file-dir "Program.fs")))
    (stubbing-process-functions
     (stub-fn fsharp-ac-message-safely msg
       (using-file f
         (noflet ((fsharp-ac--in-project-p (file) t))
           (fsharp-ac-can-make-request)
           (should (null msg))))))))

(check "error message if no project file loaded"
  (let ((f (concat fs-file-dir "Program.fs")))
    (stubbing-process-functions
     (stub-fn fsharp-ac-message-safely msg
       (using-file f
         (noflet ((fsharp-ac--in-project-p (file)))
           (fsharp-ac-can-make-request)
           (should-match "not part of the loaded project" msg)))))))

(check "no error message if failed request from doc mode"
  (stubbing-process-functions
   (stub-fn message msg
     (noflet ((fsharp-ac--process-live-p (host)))
       (using-temp-file "test.fsx"
         (fsharp-doc--request-info)
         (should (null msg)))))))

(check "no error message if failed request from parsing"
  (stubbing-process-functions
   (stub-fn message msg
     (noflet ((fsharp-ac--process-live-p (host)))
       (using-temp-file "test.fsx"
         (fsharp-ac--parse-current-file)
         (should (null msg)))))))

;;; Only parse if the file has changed

(check "do not reparse if file has not changed"
       (let ((counter 0)
             (flycheck-disabled-checkers '(fsharp-fsautocomplete fsharp-fsautocomplete-lint)))
         (noflet ((process-send-string (_ _) (setq counter (+ counter 1)))
                  (process-live-p (p) t)
                  (fsharp-ac--process-live-p (host) t)
                  (start-process (&rest args))
                  (set-process-filter (&rest args))
                  (fsharp-ac-completion-process (host) nil)
                  (process-buffer (p) (get-buffer-create "*fsharp-complete*"))
                  (set-process-query-on-exit-flag (&rest args))
                                        ;              (process-send-string (&rest args))
                  (process-mark (proc) (point-max))
                  (log-to-proc-buf (p s)))
                 (using-temp-file "test.fsx"
                                  (should= counter 0)
                                  (fsharp-ac-parse-current-buffer)
                                  (should= counter 1)
                                  (fsharp-ac-parse-current-buffer)
                                  (should= counter 1)
                                  (insert "let x = 1\n")
                                  (fsharp-ac-parse-current-buffer)
                                  (should= counter 2)
                                  (fsharp-ac-parse-current-buffer)
                                  (should= counter 2)))))
