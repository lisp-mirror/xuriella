;;; -*- show-trailing-whitespace: t; indent-tabs-mode: nil -*-

;;; Copyright (c) 2007,2008 David Lichteblau, Ivan Shvedunov.
;;; All rights reserved.

;;; Redistribution and use in source and binary forms, with or without
;;; modification, are permitted provided that the following conditions
;;; are met:
;;;
;;;   * Redistributions of source code must retain the above copyright
;;;     notice, this list of conditions and the following disclaimer.
;;;
;;;   * Redistributions in binary form must reproduce the above
;;;     copyright notice, this list of conditions and the following
;;;     disclaimer in the documentation and/or other materials
;;;     provided with the distribution.
;;;
;;; THIS SOFTWARE IS PROVIDED BY THE AUTHOR 'AS IS' AND ANY EXPRESSED
;;; OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
;;; WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
;;; ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY
;;; DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
;;; DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE
;;; GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
;;; INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY,
;;; WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
;;; NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
;;; SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

(in-package :xuriella)

#+sbcl
(declaim (optimize (debug 2)))


;;;; Instructions

(defparameter *builtin-instructions* (make-hash-table :test 'equal))

(defmacro define-instruction (name (args-var env-var) &body body)
  `(setf (get ',name 'xslt-instruction)
         (lambda (,args-var ,env-var)
           (declare (ignorable ,env-var))
           ,@body)))

(define-instruction if (args env)
  (destructuring-bind (test then &optional else) args
    (let ((test-thunk (compile-xpath test env))
          (then-thunk (compile-instruction then env))
          (else-thunk (when else (compile-instruction else env))))
      (lambda (ctx)
        (cond
          ((xpath:boolean-value (funcall test-thunk ctx))
           (funcall then-thunk ctx))
          (else-thunk
           (funcall else-thunk ctx)))))))

(define-instruction when (args env)
  (destructuring-bind (test &rest body) args
    (compile-instruction `(if ,test (progn ,@body)) env)))

(define-instruction unless (args env)
  (destructuring-bind (test &rest body) args
    (compile-instruction `(if (:not ,test) (progn ,@body)) env)))

(define-instruction cond (args env)
  (if args
      (destructuring-bind ((test &body body) &rest clauses) args
        (compile-instruction (if (eq test t)
                                 `(progn ,@body)
                                 `(if ,test
                                      (progn ,@body)
                                      (cond ,@clauses)))
                             env))
      (constantly nil)))

(define-instruction progn (args env)
  (if args
      (let ((first-thunk (compile-instruction (first args) env))
            (rest-thunk (compile-instruction `(progn ,@(rest args)) env)))
        (lambda (ctx)
          (funcall first-thunk ctx)
          (funcall rest-thunk ctx)))
      (constantly nil)))

(defun decode-qname/runtime (qname namespaces attributep)
  (handler-case
      (multiple-value-bind (prefix local-name)
          (split-qname qname)
        (values local-name
                (if (or prefix (not attributep))
                    (or (cdr (assoc prefix namespaces :test 'equal))
                        (xslt-error "namespace not found: ~A" prefix))
                    "")
                prefix))
    (cxml:well-formedness-violation ()
      (xslt-error "not a qname: ~A" qname))))

(define-instruction xsl:element (args env)
  (destructuring-bind ((name &key namespace use-attribute-sets)
                       &body body)
      args
    (declare (ignore use-attribute-sets)) ;fixme
    (multiple-value-bind (name-thunk constant-name-p)
        (compile-avt name env)
      (multiple-value-bind (ns-thunk constant-ns-p)
          (if namespace
              (compile-avt namespace env)
              (values nil t))
        (let ((body-thunk (compile-instruction `(progn ,@body) env)))
          (if (and constant-name-p constant-ns-p)
              (compile-element/constant-name name namespace env body-thunk)
              (compile-element/runtime name-thunk ns-thunk body-thunk)))))))

(defun compile-element/constant-name (qname namespace env body-thunk)
  ;; the simple case: compile-time decoding of the QName
  (multiple-value-bind (local-name uri prefix)
      (decode-qname qname env nil :allow-unknown-namespace t)
    (when namespace
      (setf uri namespace))
    (lambda (ctx)
      (cond
        (uri
         (with-element (local-name uri :suggested-prefix prefix)
           (funcall body-thunk ctx)))
        (t
         ;; ERROR rather than CERROR because saxon doesn't do the recovery,
         ;; and the official output illustrates recovery but is useless as
         ;; always.
         (xslt-error "namespace not found: ~A" prefix)
         #+(or)
         (let ((*start-tag-written-p* t))
           (declare (special *start-tag-written-p*))
           (funcall body-thunk ctx)))))))

(defun compile-element/runtime (name-thunk ns-thunk body-thunk)
  ;; run-time decoding of the QName, but using the same namespaces
  ;; that would have been known at compilation time.
  (let ((namespaces *namespaces*))
    (lambda (ctx)
      (let ((qname (funcall name-thunk ctx)))
        (multiple-value-bind (local-name uri prefix)
            (decode-qname/runtime qname namespaces nil)
          (when ns-thunk
            (setf uri (funcall ns-thunk ctx)))
          (unless uri
            (setf uri ""))
          (with-element (local-name uri :suggested-prefix prefix)
            (funcall body-thunk ctx)))))))

(define-instruction xsl:use-attribute-sets (args env)
  (destructuring-bind (str) args
    (let ((sets (mapcar (lambda (qname)
                          (multiple-value-list (decode-qname qname env nil)))
                        (words str))))
      (lambda (ctx)
        (loop for (local-name uri nil) in sets do
             (dolist (thunk (find-attribute-set local-name uri))
               (funcall thunk ctx)))))))

(define-instruction xsl:attribute (args env)
  (destructuring-bind ((name &key namespace) &body body) args
    (when (null name)
      (xslt-error "xsl:attribute: name not specified"))
    (multiple-value-bind (name-thunk constant-name-p)
        (compile-avt name env)
      (multiple-value-bind (ns-thunk constant-ns-p)
          (if namespace
              (compile-avt namespace env)
              (values nil t))
        (let ((value-thunk (compile-instruction `(progn ,@body) env)))
          (if (and constant-name-p constant-ns-p)
              (compile-attribute/constant-name name namespace env value-thunk)
              (compile-attribute/runtime name-thunk ns-thunk value-thunk)))))))

(defun compile-attribute/constant-name (qname namespace env value-thunk)
  ;; the simple case: compile-time decoding of the QName
  (multiple-value-bind (local-name uri prefix)
      (decode-qname qname env t :allow-unknown-namespace t)
    (when namespace
      (setf uri namespace))
    (lambda (ctx)
      (write-attribute local-name
                       (or uri "")
                       (with-toplevel-text-output-sink (s)
                         (with-xml-output s
                           (funcall value-thunk ctx)))
                       :suggested-prefix prefix))))

(defun compile-attribute/runtime (name-thunk ns-thunk value-thunk)
  ;; run-time decoding of the QName, but using the same namespaces
  ;; that would have been known at compilation time.
  (let ((namespaces *namespaces*))
    (lambda (ctx)
      (let ((qname (funcall name-thunk ctx)))
        (multiple-value-bind (local-name uri prefix)
            (decode-qname/runtime qname namespaces t)
          (when ns-thunk
            (setf uri (funcall ns-thunk ctx)))
          (write-attribute local-name
                           (or uri "")
                           (with-toplevel-text-output-sink (s)
                             (with-xml-output s
                               (funcall value-thunk ctx)))
                           :suggested-prefix prefix))))))

;; zzz Also elides (later) namespaces hidden by (earlier) ones.
;; zzz Reverses order.
;;
;; zzz fix the huge kludge that included-after-all-for-weird-reason-uris is
;;
(defun remove-excluded-namespaces
    (namespaces &optional (excluded-uris *excluded-namespaces*)
                          included-after-all-for-weird-reason-uris)
  (let ((koerbchen '())
        (kroepfchen '()))
    (loop
       for cons in namespaces
       for (prefix* . uri) = cons
       for prefix = (or prefix* "")
       do
         (cond
           ((find prefix kroepfchen :test #'equal))
           ((find prefix koerbchen :test #'equal :key #'car))
           ((and (find uri excluded-uris :test #'equal)
                 (not (find uri included-after-all-for-weird-reason-uris
                            :test #'equal)))
            (push prefix kroepfchen))
           (t
            (push cons koerbchen))))
    koerbchen))

;; FIXME!
(defun collect-literal-attribute-namespaces-KLUDGE (body)
  (loop
     for frob in body
     when (and (consp frob) (eq (car frob) 'xsl:literal-attribute))
     collect (second (second frob))))

;; FIXME!
(defun not-actually-excluded-namespaces-KLUDGE (element-uri body)
  (mapcan (lambda (uri)
            (multiple-value-bind (unaliased-uri matchp)
                (gethash uri (stylesheet-namespace-aliases *stylesheet*))
              (if matchp
                  (list unaliased-uri)
                  nil)))
          (cons element-uri
                (remove-if
                 (lambda (x) (zerop (length x)))
                 (collect-literal-attribute-namespaces-KLUDGE body)))))

(define-instruction xsl:literal-element (args env)
  (destructuring-bind
        ((local-name &optional (uri "") suggested-prefix) &body body)
      args
    (let ((body-thunk (compile-instruction `(progn ,@body) env))
          (namespaces (remove-excluded-namespaces
                       *namespaces*
                       *excluded-namespaces*
                       (not-actually-excluded-namespaces-KLUDGE uri body))))
      (lambda (ctx)
        (with-element (local-name (or uri "")
                                  :suggested-prefix suggested-prefix
                                  :extra-namespaces namespaces
                                  :process-aliases t)
          (funcall body-thunk ctx))))))

(define-instruction xsl:literal-attribute (args env)
  (destructuring-bind ((local-name &optional uri suggested-prefix) value) args
    (let ((value-thunk (compile-avt value env)))
      (lambda (ctx)
        (write-attribute local-name
                         uri
                         (funcall value-thunk ctx)
                         :process-aliases t
                         :suggested-prefix suggested-prefix)))))

(define-instruction xsl:text (args env)
  (destructuring-bind (str) args
    (lambda (ctx)
      (declare (ignore ctx))
      (write-text str))))

(define-instruction xsl:unescaped-text (args env)
  (destructuring-bind (str) args
    (lambda (ctx)
      (declare (ignore ctx))
      (write-unescaped str))))

(define-instruction xsl:processing-instruction (args env)
  (destructuring-bind (name &rest body) args
    (let ((name-thunk (compile-avt name env))
          (value-thunk (compile-instruction `(progn ,@body) env)))
      (lambda (ctx)
        (write-processing-instruction
         (funcall name-thunk ctx)
         (with-toplevel-text-output-sink (s)
           (with-xml-output s
             (funcall value-thunk ctx))))))))

(define-instruction xsl:comment (args env)
  (let ((value-thunk (compile-instruction `(progn ,@args) env)))
    (lambda (ctx)
      (write-comment (with-toplevel-text-output-sink (s)
                       (with-xml-output s
                         (funcall value-thunk ctx)))))))

(define-instruction xsl:value-of (args env)
  (destructuring-bind (xpath) args
    (let ((thunk (compile-xpath xpath env)))
      (xslt-trace-thunk
       (lambda (ctx)
         (write-text (xpath:string-value (funcall thunk ctx))))
       "value-of ~s = ~s" xpath :result))))

(define-instruction xsl:unescaped-value-of (args env)
  (destructuring-bind (xpath) args
    (let ((thunk (compile-xpath xpath env)))
      (lambda (ctx)
        (write-unescaped (xpath:string-value (funcall thunk ctx)))))))

(define-instruction xsl:copy-of (args env)
  (destructuring-bind (xpath) args
    (let ((thunk (compile-xpath xpath env))
          ;; FIXME: what was this for?  --david
          #+(or) (v (intern-variable "varName" "")))
      (xslt-trace-thunk
       (lambda (ctx)
         (let ((result (funcall thunk ctx)))
           (typecase result
             (xpath:node-set ;; FIXME: variables can contain node sets w/fragments inside. Maybe just fragments would do?
              (xpath:map-node-set #'copy-into-result (xpath:sort-node-set result)))
             (result-tree-fragment
              (copy-into-result result))
             (t
              (write-text (xpath:string-value result))))))
       "copy-of ~s" xpath))))

(defun copy-into-result (node)
  (cond
    ((result-tree-fragment-p node)
     (stp:do-children (child (result-tree-fragment-node node))
       (copy-into-result child)))
    ((xpath-protocol:node-type-p node :element)
     (with-element ((xpath-protocol:local-name node)
                    (xpath-protocol:namespace-uri node)
                    :suggested-prefix (xpath-protocol:namespace-prefix node)
                    :extra-namespaces (namespaces-as-alist node))
       (map-pipe-eagerly #'copy-into-result
                         (xpath-protocol:attribute-pipe node))
       (map-pipe-eagerly #'copy-into-result
                         (xpath-protocol:child-pipe node))))
    ((xpath-protocol:node-type-p node :document)
     (map-pipe-eagerly #'copy-into-result
                       (xpath-protocol:child-pipe node)))
    (t
     (copy-leaf-node node))))

(defparameter *lower-first-order*
  #(#\  #\! #\" #\# #\$ #\% #\& #\' #\( #\) #\* #\+ #\, #\- #\. #\/ #\0 #\1 #\2
    #\3 #\4 #\5 #\6 #\7 #\8 #\9 #\: #\; #\< #\= #\> #\? #\@ #\H #\J #\L #\N #\P
    #\R #\T #\V #\X #\Z #\\ #\^ #\` #\b #\d #\f #\h #\j #\l #\n #\p #\r #\t #\v
    #\x #\z #\A #\B #\C #\D #\E #\F #\G #\I #\K #\M #\O #\Q #\S #\U #\W #\Y #\[
    #\] #\_ #\a #\c #\e #\g #\i #\k #\m #\o #\q #\s #\u #\w #\y #\{ #\| #\} #\~
    #\Rubout))

(defparameter *upper-first-order*
  #(#\  #\! #\" #\# #\$ #\% #\& #\' #\( #\) #\* #\+ #\, #\- #\. #\/ #\0 #\1 #\2
    #\3 #\4 #\5 #\6 #\7 #\8 #\9 #\: #\; #\< #\= #\> #\? #\@ #\G #\I #\K #\M #\O
    #\Q #\S #\U #\W #\Y #\[ #\] #\_ #\a #\c #\e #\g #\i #\k #\m #\o #\q #\s #\u
    #\w #\y #\A #\B #\C #\D #\E #\F #\H #\J #\L #\N #\P #\R #\T #\V #\X #\Z #\\
    #\^ #\` #\b #\d #\f #\h #\j #\l #\n #\p #\r #\t #\v #\x #\z #\{ #\| #\} #\~
    #\Rubout))

(defun collation-char (char table)
  (let ((code (char-code char)))
    (if (<= 32 code 127)
        (elt table (- code 32))
        char)))

(defun make-collation-key (str table)
  (map 'string (lambda (char) (collation-char char table)) str))

(defun compare-numbers (n-a n-b)
  (cond ((and (xpath::nan-p n-a)
              (not (xpath::nan-p n-b)))
         -1)
        ((and (not (xpath::nan-p n-a))
              (xpath::nan-p n-b))
         1)
        ((xpath::compare-numbers '< n-a n-b) -1)
        ((xpath::compare-numbers '> n-a n-b) 1)
        (t 0)))

(defun mismatch* (a b)
  (let ((pos (mismatch a b)))
    (if (and pos (< pos (min (length a) (length b))))
        pos
        nil)))

(defun compare-strings (i j char-table)
  ;; zzz Unicode support!
  (let ((pos
         (or (mismatch* (string-downcase i) (string-downcase j))
             (mismatch* i j))))
    (if pos
        (let ((c (collation-char (elt i pos) char-table))
              (d (collation-char (elt j pos) char-table)))
          (cond
            ((char< c d) -1)
            ((char= c d) 0)
            (t 1)))
        (signum (- (length i) (length j))))))

(defun sort/@data-type (str)
  (cond
    ((equal str "number")
     t)
    ((or (null str) (equal str "text"))
     nil)
    (t
     (xslt-error "invalid data-type in sort"))))

(defun sort/@case-order (str)
  (cond
    ((equal str "lower-first")
     *lower-first-order*)
    ((or (null str) (equal str "upper-first"))
     *upper-first-order*)
    (t
     (xslt-error "invalid case-order in sort"))))

(defun sort/@order (str)
  (cond
    ((equal str "descending")
     -1)
    ((or (null str) (equal str "ascending"))
     1)
    (t
     (xslt-error "invalid order in sort"))))

(defun compile-optional-avt (template-string env)
  (if template-string
      (compile-avt template-string env)
      (values (constantly nil) t)))

(defun make-sorter/lazy (spec env)
  (destructuring-bind (&key select lang data-type order case-order)
      (cdr spec)
    (let ((select-thunk (compile-xpath (or select ".") env))
          (lang-thunk (compile-optional-avt lang env))
          (data-type-thunk (compile-optional-avt data-type env))
          (order-thunk (compile-optional-avt order env))
          (case-order-thunk (compile-optional-avt case-order env)))
      (lambda (ctx)
        (let ((numberp (sort/@data-type (funcall data-type-thunk ctx)))
              (char-table (sort/@case-order (funcall case-order-thunk ctx)))
              (f (sort/@order (funcall order-thunk ctx)))
              (lang (funcall lang-thunk ctx)))
          (declare (ignore lang))
          (lambda (a b)
            (let ((i (xpath:string-value (funcall select-thunk a)))
                  (j (xpath:string-value (funcall select-thunk b))))
              (* f
                 (if numberp
                     (compare-numbers (xpath:number-value i)
                                      (xpath:number-value j))
                     (compare-strings i j char-table))))))))))

(defun compose-sorters/lazy (sorters)
  (if sorters
      (let ((this-thunk (car sorters))
            (next-thunk (compose-sorters/lazy (rest sorters))))
        (lambda (ctx)
          (let ((this (funcall this-thunk ctx))
                (next (funcall next-thunk ctx)))
            (lambda (a b)
              (let ((d (funcall this a b)))
                (if (zerop d)
                    (funcall next a b)
                    d))))))
      (lambda (ctx)
        (declare (ignore ctx))
        (constantly 0))))

(defun make-sort-predicate/lazy (decls env)
  (let ((sorter-thunk
         (compose-sorters/lazy
          (mapcar (lambda (x) (make-sorter/lazy x env)) decls))))
    (lambda (ctx)
      (let ((sorter (funcall sorter-thunk ctx)))
        (lambda (a b)
          (minusp (funcall sorter a b)))))))

(defun contextify-node-list (nodes)
  (let ((size (length nodes)))
    (loop
       for position from 1
       for node in nodes
       collect
         (xpath:make-context node size position))))

(define-instruction xsl:for-each (args env)
  (destructuring-bind (select &optional decls &rest body) args
    (unless (and (consp decls)
                 (eq (car decls) 'declare))
      (push decls body)
      (setf decls nil))
    (let ((select-thunk (compile-xpath select env))
          (body-thunk (compile-instruction `(progn ,@body) env))
          (sort-predicate-thunk
           (when (cdr decls)
             (make-sort-predicate/lazy (cdr decls) env))))
      (lambda (ctx)
        (let ((selected (funcall select-thunk ctx))
              (*apply-imports*
               (lambda (&optional ignore)
                 (declare (ignore ignore))
                 (xslt-error "apply-imports used in for-each"))))
          (unless (xpath:node-set-p selected)
            (xslt-error "for-each select expression should yield a node-set"))
          (let ((nodes (xpath::force (xpath::sorted-pipe-of selected))))
            (when sort-predicate-thunk
              (setf nodes
                    (mapcar #'xpath:context-node
                            (stable-sort (contextify-node-list nodes)
                                         (funcall sort-predicate-thunk ctx)))))
            (dolist (ctx (contextify-node-list nodes))
              (funcall body-thunk ctx))))))))

(define-instruction xsl:with-namespaces (args env)
  (destructuring-bind ((&rest forms) &rest body) args
    (let ((*namespaces* *namespaces*))
      (dolist (form forms)
        (destructuring-bind (prefix uri) form
          (push (cons prefix uri) *namespaces*)))
      (compile-instruction `(progn ,@body) env))))

(define-instruction xsl:with-excluded-namespaces (args env)
  (destructuring-bind ((&rest uris) &rest body) args
    (let ((*excluded-namespaces* (append uris *excluded-namespaces*)))
      (compile-instruction `(progn ,@body) env))))

(define-instruction xsl:with-extension-namespaces (args env)
  (destructuring-bind ((&rest uris) &rest body) args
    (let ((*extension-namespaces* (append uris *extension-namespaces*)))
      (compile-instruction `(progn ,@body) env))))

(define-instruction xsl:with-version (args env)
  (destructuring-bind (version &rest body) args
    (let ((*forwards-compatible-p* (not (equal version "1.0"))))
      (compile-instruction `(progn ,@body) env))))

;; XSLT disallows multiple definitions of the same variable within a
;; template.  Local variables can shadow global variables though.
;; Since our LET syntax makes it natural to shadow local variables the
;; Lisp way, we check for duplicate variables only where instructed to
;; by the XML syntax parser using WITH-DUPLICATES-CHECK:
(defvar *template-variables* nil)

(define-instruction xsl:with-duplicates-check (args env)
  (let ((*template-variables* *template-variables*))
    (destructuring-bind ((&rest qnames) &rest body) args
      (dolist (qname qnames)
        (multiple-value-bind (local-name uri)
            (decode-qname qname env nil)
          (let ((key (cons local-name uri)))
            (when (find key *template-variables* :test #'equal)
              (xslt-error "duplicate variable: ~A, ~A" local-name uri))
            (push key *template-variables*))))
      (compile-instruction `(progn ,@body) env))))

(define-instruction xsl:with-base-uri (args env)
  (destructuring-bind (uri &rest body) args
    (let ((*instruction-base-uri* uri))
      (compile-instruction `(progn ,@body) env))))

(defstruct (result-tree-fragment
             (:constructor make-result-tree-fragment (node)))
  node)

(define-default-method xpath-protocol:node-p
    ((node result-tree-fragment))
  t)

(define-default-method xpath-protocol:node-text
    ((node result-tree-fragment))
  (xpath-protocol:node-text (result-tree-fragment-node node)))

(defun apply-to-result-tree-fragment (ctx thunk)
  (let ((document
         (with-xml-output (make-stpx-builder)
           (with-element ("fragment" "")
             (funcall thunk ctx)))))
    (make-result-tree-fragment (stp:document-element document))))

(defun compile-var-bindings/nointern (forms env)
  (loop
    for (name value) in forms
    collect (multiple-value-bind (local-name uri)
                (decode-qname name env nil)
              (list (cons local-name uri)
                    (xslt-trace-thunk
                     (compile-value-thunk value env)
                     "local variable ~s = ~s" name :result)))))

(define-instruction let (args env)
  (destructuring-bind ((&rest forms) &rest body) args
    (let* ((old-top (length *lexical-variable-declarations*))
           (vars-and-names (compile-var-bindings/nointern forms env))
           (vars-and-positions
            (loop for ((local-name . uri) thunk) in vars-and-names
               collect
                 (list (push-variable local-name
                                      uri
                                      *lexical-variable-declarations*)
                       thunk))))
      (let ((thunk (compile-instruction `(progn ,@body) env)))
        (fill *lexical-variable-declarations* nil :start old-top)
        (lambda (ctx)
          (loop for (index var-thunk) in vars-and-positions
             do (setf (lexical-variable-value index)
                      (funcall var-thunk ctx)))
          (funcall thunk ctx))))))

(define-instruction let* (args env)
  (destructuring-bind ((&rest forms) &rest body) args
    (if forms
        (compile-instruction `(let (,(car forms))
                                (let* (,@(cdr forms))
                                  ,@body))
                             env)
        (compile-instruction `(progn ,@body) env))))

(define-instruction xsl:message (args env)
  (compile-message #'warn args env))

(define-instruction xsl:terminate (args env)
  (compile-message #'xslt-error args env))

(defun namespaces-as-alist (element)
  (let ((namespaces '()))
    (do-pipe (ns (xpath-protocol:namespace-pipe element))
      (push (cons (xpath-protocol:local-name ns)
                  (xpath-protocol:node-text ns))
            namespaces))
    namespaces))

(define-instruction xsl:copy (args env)
  (let ((body (compile-instruction `(progn ,@args) env)))
    (lambda (ctx)
      (let ((node (xpath:context-node ctx)))
        (cond
          ((xpath-protocol:node-type-p node :element)
           (with-element
               ((xpath-protocol:local-name node)
                (xpath-protocol:namespace-uri node)
                :suggested-prefix (xpath-protocol:namespace-prefix node)
                :extra-namespaces (namespaces-as-alist node))
             (funcall body ctx)))
          ((xpath-protocol:node-type-p node :document)
           (funcall body ctx))
          (t
           (copy-leaf-node node)))))))

(defun copy-leaf-node (node)
  (cond
    ((xpath-protocol:node-type-p node :text)
     (etypecase (if (typep node 'stripping-node)
                    (stripping-node-target node)
                    node)
       (unescaped-text (write-unescaped (xpath-protocol:node-text node)))
       (stp:text (write-text (xpath-protocol:node-text node)))))
    ((xpath-protocol:node-type-p node :comment)
     (write-comment (xpath-protocol:node-text node)))
    ((xpath-protocol:node-type-p node :processing-instruction)
     (write-processing-instruction
         (xpath-protocol:processing-instruction-target node)
       (xpath-protocol:node-text node)))
    ((xpath-protocol:node-type-p node :attribute)
     (write-attribute
      (xpath-protocol:local-name node)
      (xpath-protocol:namespace-uri node)
      (xpath-protocol:node-text node)
      :suggested-prefix (xpath-protocol:namespace-prefix node)))
    ((xpath-protocol:node-type-p node :namespace)
     (write-extra-namespace
      (xpath-protocol:local-name node)
      (xpath-protocol:node-text node)
      nil))
    (t
     (error "don't know how to copy node ~A" node))))

(defun compile-message (fn args env)
  (let ((thunk (compile-instruction `(progn ,@args) env)))
    (lambda (ctx)
      (funcall fn
               (with-xml-output (cxml:make-string-sink)
                 (funcall thunk ctx))))))

(define-instruction xsl:apply-templates (args env)
  (destructuring-bind ((&key select mode) &rest param-binding-specs) args
    (let* ((decls
            (when (and (consp (car param-binding-specs))
                       (eq (caar param-binding-specs) 'declare))
              (cdr (pop param-binding-specs))))
           (select-thunk
            (compile-xpath (or select "child::node()") env))
           (param-bindings
            (compile-var-bindings param-binding-specs env))
           (sort-predicate-thunk
            (when decls
              (make-sort-predicate/lazy decls env))))
      (multiple-value-bind (mode-local-name mode-uri)
          (and mode (decode-qname mode env nil))
        (lambda (ctx)
          (apply-templates/list
           (xpath::force
            (xpath::sorted-pipe-of (funcall select-thunk ctx)))
           :param-bindings
           (loop for (name nil value-thunk) in param-bindings
              collect (list name (funcall value-thunk ctx)))
           :sort-predicate (when sort-predicate-thunk
                             (funcall sort-predicate-thunk ctx))
           :mode (when mode
                   (or (find-mode *stylesheet*
                                  mode-local-name
                                  mode-uri)
                       *empty-mode*))))))))

(define-instruction xsl:apply-imports (args env)
  (declare (ignore args env))
  (lambda (ctx)
    (declare (ignore ctx))
    (funcall *apply-imports*)))

(define-instruction xsl:call-template (args env)
  (destructuring-bind (name &rest param-binding-specs) args
    (let ((param-bindings
           (compile-var-bindings param-binding-specs env)))
      (multiple-value-bind (local-name uri)
          (decode-qname name env nil)
        (setf name (cons local-name uri)))
      (lambda (ctx)
        (call-template ctx name
                       (loop for (name nil value-thunk) in param-bindings
                          collect (list name (funcall value-thunk ctx))))))))

(defun compile-instruction (form env)
  "@arg[form]{An XSLT instruction in sexp representation}
   @arg[env]{An XSLT environment}
   @return{A compiled function}

   @short{Compiles an XSLT instruction.}

   This function is for use in XSLT extensions.  When defining an
   extension using @macro{define-extension-compiler}, pass body forms of
   the extension that should be interpreted as XSLT instructions to this
   function.

   The environment is an opaque object, which can be obtained using
   the @code{&environment} lambda list keyword in the extension compiler."
  (xslt-trace-thunk
   (funcall (or (get (car form) 'xslt-instruction)
                (get (car form) 'extension-compiler)
                (error "undefined instruction: ~A" (car form)))
            (cdr form)
            env)
   "instruction ~s" (car form)))

;;: WTF: "A right curly brace inside a Literal in an expression is not
;;; recognized as terminating the expression."
;;;
;;; Da hilft nur tagbody.
(defun parse-attribute-value-template (template-string)
  (with-input-from-string (input template-string)
    (let ((ordinary (make-string-output-stream))
          (xpath (make-string-output-stream))
          (tokens '())
          (c (read-char input nil :eof)))
      (flet ((emit ()
               (let ((o (get-output-stream-string ordinary)))
                 (when (plusp (length o))
                   (push (list :data o) tokens)))
               (let ((x (get-output-stream-string xpath)))
                 (when (plusp (length x))
                   (push (list :xpath x) tokens))))
             (collect-ordinary ()
               (write-char c ordinary))
             (collect-xpath ()
               (write-char c xpath)))
        (macrolet ((goto (target)
                     `(progn
                        (setf c (read-char input nil :eof))
                        (go ,target))))
          (tagbody
           ordinary
             (case c
               (#\{
                (goto seen{))
               (#\}
                (goto seen-stray-}))
               (:eof
                (go done)))
             (collect-ordinary)
             (goto ordinary)

           seen{
             (case c
               (#\{
                (collect-ordinary)
                (goto ordinary))
               (#\'
                (collect-xpath)
                (goto in-single-quote))
               (:eof
                (xslt-error "unexpected end of avt")))
             (emit)
             (collect-xpath)
             (goto xpath)

           xpath
             (case c
               (#\'
                (collect-xpath)
                (goto in-single-quote))
               (#\"
                (collect-xpath)
                (goto in-double-quote))
               (#\}
                (goto seen-closing-}))
               (:eof
                (xslt-error "unexpected end of avt")))
             (collect-xpath)
             (goto xpath)

           in-single-quote
             (case c
               (#\'
                (collect-xpath)
                (goto xpath))
               (:eof
                (xslt-error "unexpected end of avt")))
             (collect-xpath)
             (goto in-single-quote)

           in-double-quote
             (case c
               (#\"
                (collect-xpath)
                (goto xpath))
               (:eof
                (xslt-error "unexpected end of avt")))
             (collect-xpath)
             (goto in-double-quote)

           seen-closing-}
             (case c
               (#\}
                (emit)
                (goto seen-stray-}))
               (#\{
                (emit)
                (goto xpath))
               (:eof
                (goto done)))
             (emit)
             (collect-ordinary)
             (goto ordinary)

           seen-stray-}
             (case c
               (#\}
                (collect-ordinary)
                (goto ordinary)))
             (xslt-error "unexpected closing brace in avt")

           done
             (emit))))
      (nreverse tokens))))

(defun compile-avt (template-string env)
  (let* ((constantp t)
         (fns
          (mapcar (lambda (x)
                    (ecase (car x)
                      (:data
                       (constantly (second x)))
                      (:xpath
                       (setf constantp nil)
                       (compile-xpath (second x) env))))
                  (if template-string
                      (parse-attribute-value-template template-string)
                      (xslt-error "missing avt")))))
    (values (lambda (ctx)
              (with-output-to-string (s)
                (dolist (fn fns)
                  (write-string (xpath:string-value (funcall fn ctx)) s))))
            constantp)))


;;;; Indentation for slime

(defmacro define-indentation (name (&rest args))
  (labels ((collect-variables (list)
             (loop
                for sub in list
                append
                (etypecase sub
                  (list
                   (collect-variables sub))
                  (symbol
                   (if (eql (mismatch "&" (symbol-name sub)) 1)
                       nil
                       (list sub)))))))
    `(defmacro ,name (,@args)
       (declare (ignorable ,@(collect-variables args)))
       (error "XSL indentation helper ~A used literally in lisp code"
              ',name))))

(define-indentation xsl:element
    ((name &key namespace use-attribute-sets) &body body))
(define-indentation xsl:literal-element ((name &optional uri) &body body))
(define-indentation xsl:attribute ((name &key namespace) &body body))
(define-indentation xsl:literal-attribute ((name &optional uri) &body body))
(define-indentation xsl:text (str))
(define-indentation xsl:processing-instruction (name &body body))
(define-indentation xsl:comment (&body body))
(define-indentation xsl:value-of (xpath))
(define-indentation xsl:unescaped-value-of (xpath))
(define-indentation xsl:for-each (select &body decls-and-body))
(define-indentation xsl:message (&body body))
(define-indentation xsl:terminate (&body body))
(define-indentation xsl:apply-templates ((&key select mode) &body decls-and-body))
(define-indentation xsl:call-template (name &rest parameters))
(define-indentation xsl:copy-of (xpath))

;;;;

(defun test-instruction (form document)
  (let ((thunk (compile-instruction form (make-instance 'lexical-environment)))
        (root (cxml:parse document (stp:make-builder))))
    (with-xml-output (cxml:make-string-sink)
      (funcall thunk (xpath:make-context root)))))
