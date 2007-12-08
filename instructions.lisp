;;; -*- show-trailing-whitespace: t; indent-tabs: nil -*-

;;; Copyright (c) 2007 David Lichteblau. All rights reserved.

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

(declaim (optimize (debug 3) (safety 3) (space 0) (speed 0)))
;;;; Instructions

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
        (with-fresh-frame
          (cond
            ((xpath:boolean-value (funcall test-thunk ctx))
             (funcall then-thunk ctx))
            (else-thunk
             (funcall else-thunk ctx))))))))

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
				 `(scoped-progn ,@body)
				 `(if ,test
				      (scoped-progn ,@body)
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
	  (cxml::split-qname qname)
	(values local-name
		(if (or prefix (not attributep))
		    (cdr (assoc prefix namespaces :test 'equal))
		    "")
		prefix))
    (cxml:well-formedness-violation ()
      (xslt-error "not a qname: ~A" qname))))

(define-instruction scoped-progn (args env)
  (if args
      (let ((first-thunk (compile-instruction (first args) env))
	    (rest-thunk (compile-instruction `(progn ,@(rest args)) env)))
	(lambda (ctx)
          (with-fresh-frame
            (funcall first-thunk ctx)
            (funcall rest-thunk ctx))))
      (constantly nil)))

(define-instruction xsl:element (args env)
  (destructuring-bind ((name &key namespace use-attribute-sets)
		       &body body)
      args
    (declare (ignore use-attribute-sets)) ;fixme
    (multiple-value-bind (name-thunk constant-name-p)
	(compile-attribute-value-template name env)
      (let ((body-thunk (compile-instruction `(scoped-progn ,@body) env)))
	(if constant-name-p
	    (compile-element/constant-name name namespace env body-thunk)
	    (compile-element/runtime name-thunk namespace body-thunk))))))

(defun compile-element/constant-name (qname namespace env body-thunk)
  ;; the simple case: compile-time decoding of the QName
  (multiple-value-bind (local-name uri prefix)
      (decode-qname qname env nil)
    (when namespace
      (setf uri namespace))
    (lambda (ctx)
      (with-element (local-name uri :suggested-prefix prefix)
	(funcall body-thunk ctx)))))

(defun compile-element/runtime (name-thunk namespace body-thunk)
  ;; run-time decoding of the QName, but using the same namespaces
  ;; that would have been known at compilation time.
  (let ((namespaces *namespaces*))
    (lambda (ctx)
      (let ((qname (funcall name-thunk ctx)))
	(multiple-value-bind (local-name uri prefix)
	    (decode-qname/runtime qname namespaces nil)
	  (when namespace
	    (setf uri namespace))
	  (lambda (ctx)
	    (with-element (local-name uri :suggested-prefix prefix)
	      (funcall body-thunk ctx))))))))

(define-instruction xsl:attribute (args env)
  (destructuring-bind ((name &key namespace) &body body) args
    (multiple-value-bind (name-thunk constant-name-p)
	(compile-attribute-value-template name env)
      (let ((value-thunk (compile-instruction `(scoped-progn ,@body) env)))
	(if constant-name-p
	    (compile-attribute/constant-name name namespace env value-thunk)
	    (compile-attribute/runtime name-thunk namespace value-thunk))))))

(defun compile-attribute/constant-name (qname namespace env value-thunk)
  ;; the simple case: compile-time decoding of the QName
  (multiple-value-bind (local-name uri prefix)
      (decode-qname qname env nil)
    (when namespace
      (setf uri namespace))
    (lambda (ctx)
      (write-attribute local-name
		       uri
		       (with-text-output-sink (s)
			 (with-xml-output s
			   (funcall value-thunk ctx)))
		       :suggested-prefix prefix))))

(defun compile-attribute/runtime (name-thunk namespace value-thunk)
  ;; run-time decoding of the QName, but using the same namespaces
  ;; that would have been known at compilation time.
  (let ((namespaces *namespaces*))
    (lambda (ctx)
      (let ((qname (funcall name-thunk ctx)))
	(multiple-value-bind (local-name uri prefix)
	    (decode-qname/runtime qname namespaces nil)
	  (when namespace
	    (setf uri namespace))
	  (lambda (ctx)
	    (write-attribute local-name
			     uri
			     (with-text-output-sink (s)
			       (with-xml-output s
				 (funcall value-thunk ctx)))
			     :suggested-prefix prefix)))))))

(defun remove-excluded-namespaces
    (namespaces &optional (excluded-uris *excluded-namespaces*))
  (let ((koerbchen '())
	(kroepfchen '()))
    (loop
       for cons in namespaces
       for (prefix . uri) = cons
       do
	 (cond
	   ((find prefix kroepfchen))
	   ((find uri *excluded-namespaces* :test #'equal)
	    (push prefix kroepfchen))
	   (t
	    (push cons koerbchen))))
    koerbchen))

(define-instruction xsl:literal-element (args env)
  (destructuring-bind
	((local-name &optional (uri "") suggested-prefix) &body body)
      args
    (let ((body-thunk (compile-instruction `(progn ,@body) env))
	  (namespaces (remove-excluded-namespaces *namespaces*)))
      (lambda (ctx)
	(with-element (local-name uri
				  :suggested-prefix suggested-prefix
				  :extra-namespaces namespaces)
	  (funcall body-thunk ctx))))))

(define-instruction xsl:literal-attribute (args env)
  (destructuring-bind ((local-name &optional uri suggested-prefix) value) args
    #'(lambda (ctx)
	(declare (ignore ctx))
	(write-attribute local-name
			 uri
			 value
			 :suggested-prefix suggested-prefix))))

(define-instruction xsl:text (args env)
  (destructuring-bind (str) args
    (lambda (ctx)
      (declare (ignore ctx))
      (write-text str))))

(define-instruction xsl:processing-instruction (args env)
  (destructuring-bind (name &rest body) args
    (let ((name-thunk (compile-attribute-value-template name env))
	  (value-thunk (compile-instruction `(scoped-progn ,@body) env)))
      (lambda (ctx)
	(write-processing-instruction
	 (funcall name-thunk ctx)
	 (with-text-output-sink (s)
	   (with-xml-output s
	     (funcall value-thunk ctx))))))))

(define-instruction xsl:comment (args env)
  (destructuring-bind (str) args
    (lambda (ctx)
      (declare (ignore ctx))
      (write-comment str))))

(define-instruction xsl:value-of (args env)
  (destructuring-bind (xpath) args
    (let ((thunk (compile-xpath xpath env)))
      (lambda (ctx)
	(write-text (xpath:string-value (funcall thunk ctx)))))))

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
      (lambda (ctx)
	(let ((result (funcall thunk ctx)))
	  (typecase result
	    (xpath:node-set ;; FIXME: variables can contain node sets w/fragments inside. Maybe just fragments would do?
	     (xpath:map-node-set #'copy-into-result result))
	    (result-tree-fragment
	     (copy-into-result result))
	    (t
	     (write-text (xpath:string-value result)))))))))

(defun copy-into-result (node)
  (cond
    ((result-tree-fragment-p node)
     (stp:do-children (child (result-tree-fragment-node node))
       (copy-into-result child)))
    ((xpath-protocol:node-type-p node :element)
     (with-element ((xpath-protocol:local-name node)
		    (xpath-protocol:namespace-uri node)
		    :suggested-prefix (xpath-protocol:namespace-prefix node)
		    ;; FIXME: is remove-excluded-namespaces correct here?
		    :extra-namespaces (remove-excluded-namespaces
				       (namespaces-as-alist node)))
       (map-pipe-eagerly #'copy-into-result
			 (xpath-protocol:attribute-pipe node))
       (map-pipe-eagerly #'copy-into-result
			 (xpath-protocol:child-pipe node))))
    ((xpath-protocol:node-type-p node :document)
     (map-pipe-eagerly #'copy-into-result
		       (xpath-protocol:child-pipe node)))
    (t
     (copy-leaf-node node))))

(define-instruction xsl:for-each (args env)
  (destructuring-bind (select &optional decls &rest body) args
    (when (and (consp decls)
	       (not (eq (car decls) 'declare)))
      (push decls body)
      (setf decls nil))
    (let ((select-thunk (compile-xpath select env))
	  (body-thunk (compile-instruction `(scoped-progn ,@body) env))
	  (sorter
	   ;; fixme: parse decls here
	   #'identity))
      (lambda (ctx)
	(let* ((nodes (xpath:all-nodes (funcall sorter (funcall select-thunk ctx))))
	       (n (length nodes)))
	  (loop
	     for node in nodes
	     for i from 1
	     do
	       (funcall body-thunk
			(xpath:make-context node (lambda () n) i))))))))

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

;;; FIXME
(defstruct (result-tree-fragment
	     (:constructor make-result-tree-fragment (node)))
  node)

(defmethod xpath-protocol:string-value ((node result-tree-fragment))
  (xpath-protocol:string-value (result-tree-fragment-node node)))

(defun apply-to-result-tree-fragment (ctx thunk)
  (let ((document
	 (with-xml-output (stp:make-builder)
	   (with-element ("fragment" "")
	     (funcall thunk ctx)))))
    (xpath::make-node-set
     (list (make-result-tree-fragment (stp:document-element document))))))

(define-instruction let (args env)
  (destructuring-bind ((&rest forms) &rest body) args
    (let* ((var-bindings (compile-var-bindings forms env))
           (thunk (compile-instruction `(progn ,@body) env)))
      (lambda (ctx)
        ;; FIXME: should (again) detect duplicate definitions at compile time
        (loop for (gensym var-thunk) in var-bindings
              do (if (has-inner-binding-p gensym)
                     (xslt-error "duplicate definition of ~A" gensym) ;; FIXME (find name by gensym)
                     (setf (get-frame-value gensym)
                           (funcall var-thunk ctx))))
        (funcall thunk ctx)))))

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
  (compile-message #'error args env))

(defun namespaces-as-alist (element)
  (let ((namespaces '()))
    (do-pipe (ns (xpath-protocol:namespace-pipe element))
      (push (cons (xpath-protocol:local-name ns)
		  (xpath-protocol:namespace-uri ns))
	    namespaces))
    namespaces))

(define-instruction xsl:copy (args env)
  (destructuring-bind ((&key use-attribute-sets) &rest rest)
      args
    (let ((body (compile-instruction `(scoped-progn ,@rest) env)))
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
	     (copy-leaf-node node))))))))

(defun copy-leaf-node (node)
  (cond
    ((xpath-protocol:node-type-p node :text)
     (write-text (xpath-protocol:string-value node)))
    ((xpath-protocol:node-type-p node :comment)
     (write-comment (xpath-protocol:string-value node)))
    ((xpath-protocol:node-type-p node :processing-instruction)
     (write-processing-instruction
	 (xpath-protocol:processing-instruction-target node)
       (xpath-protocol:string-value node)))
    ((xpath-protocol:node-type-p node :attribute)
     (write-attribute
      (xpath-protocol:local-name node)
      (xpath-protocol:namespace-uri node)
      (xpath-protocol:string-value node)
      :suggested-prefix (xpath-protocol:namespace-prefix node)))
    (t
     (error "don't know how to copy node ~A" node))))

(defun compile-message (fn args env)
  (let ((thunk (compile-instruction `(scoped-progn ,@args) env)))
    (lambda (ctx)
      (funcall fn
	       (with-xml-output (cxml:make-string-sink)
		 (funcall thunk ctx))))))

(define-instruction xsl:apply-templates (args env)
  (destructuring-bind ((&key select mode) &rest param-binding-specs) args
    (let ((select-thunk
	   (compile-xpath (or select "child::node()") env))
	  (param-bindings
           (compile-var-bindings param-binding-specs env)))
      (lambda (ctx)
	(let ((*mode* (if mode (find-mode mode *stylesheet*) *mode*)))
	  (apply-templates/list
	   (xpath:all-nodes (funcall select-thunk ctx))
	   (loop for (name value-thunk) in param-bindings
	         collect (list name (funcall value-thunk ctx)))))))))

(define-instruction xsl:call-template (args env)
  (destructuring-bind (name &rest param-binding-specs) args
      (let ((param-bindings
             (compile-var-bindings param-binding-specs env)))
        (multiple-value-bind (local-name uri)
            (decode-qname name env nil)
          (setf name (cons local-name uri)))
        (lambda (ctx)
          (call-template ctx name
                         (loop for (name value-thunk) in param-bindings
                               collect (list name (funcall value-thunk ctx))))))))

(defun compile-instruction (form env)
  (funcall (or (get (car form) 'xslt-instruction)
	       (error "undefined instruction: ~A" (car form)))
	   (cdr form)
	   env))

(xpath::deflexer make-attribute-template-lexer
  ("([^{]+)" (data) (values :data data))
  ("{([^}]+)}" (xpath) (values :xpath xpath)))

(defun compile-attribute-value-template (template-string env)
  (let* ((lexer (make-attribute-template-lexer template-string))
	 (constantp t)
	 (fns
	  (loop
	     collect
	       (multiple-value-bind (kind str) (funcall lexer)
		 (ecase kind
		   (:data
		    (constantly str))
		   (:xpath
		    (setf constantp nil)
		    (xpath:compile-xpath str env))
		   ((nil)
		    (return result))))
	     into result)))
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
(define-indentation xsl:comment (str))
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
