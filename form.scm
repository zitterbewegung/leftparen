#lang scheme/base

(require (file "util.scm")
         (file "repository.scm")
         (file "record.scm")
         (file "closures.scm")
         (file "web-support.scm")
         (file "files.scm")
         "settings.scm"
         (planet "web.scm" ("soegaard" "web.plt" 2 1))
         (lib "url.ss" "net"))

(provide form
         form-id
         form-markup
         grab-user-input
         make-field-type
         field-value-lift
         default-error-wrapper
         )

(define-struct form-obj (markup id))
(define form-id form-obj-id)
(define form-markup form-obj-markup)

;; the call-back : bindings-from-form -> content
;; does not save any records
(define (grab-user-input fields call-back
                         #:submit-label (submit-label "Submit")
                         #:init (init '())
                         #:skip-br (skip-br #f)
                         #:stay-on-same-page (stay-on-same-page #f))
  (form fields
        #:on-done (lambda (r) (call-back (rec-data r)))
        #:stay-on-same-page stay-on-same-page
        #:submit-label submit-label
        #:skip-save #t
        #:skip-br skip-br
        #:init init))

;;
;; form
;;
;; Example:
;;
;; (form '((title "Title" text) (content "Post" long-text))
;;       #:init '((type . meta-made-data) (kind . text))
;;       #:submit-label "Add post"
;;       #:before-save (lambda (r) ...)
;;       #:on-done (lambda (r) "all done"))
;;
;; * fields: a list of lists.  each sublist is of the form (title "Title" text).
;;     the field name (the first elt of the sub-list) must
;;     match what you want the prop name of the record to be.
;; * init: same form as previous, but provide fixed/default values for record props.
;;         You also can use init as a way of "editing".  This happens if you provide
;;         init values for fields of the form.
;;         You can also provide a record to init in which case the record is used instead
;;         of making a fresh one.
;; * submit-label: the label for the submit button of the form.
;; * before-save: a fn : rec -> / which lets you do something with r before it's saved.
;;     this is run even if skip-save=#t.
;; * on-done: this is a fn : rec -> content
;; * skip-save: set to #t if you don't want to save (on-done thunk is still executed)
;; * fail: a fn; if evals to non-#f, then return it as the answer.
;; * validate: like fail, but if returns a non-#f value then stick it in a div above
;;   the form, re-populating the form with what you typed in (i.e., fn should return
;;   an error message).
;; * use-if-exists: if set to a property name, then don't create a fresh record
;;    if there's already one that's equal to it. (XXX bad name)
;; * stamp-user: if a rec is given then assume it's a user rec and stamp it on the record
;;   in the created-by property.
;; * stamp-time: if non-#f, then stamp the current time for the created_at property.
;;    default is #t
;; * return-form-obj: returns a form struct instead of raw form markup.
;;
;; "form" is defined just below "form-aux".
(define (form-aux fields
                  #:recur recur ; provided automatically by form
                  #:init (init '())
                  #:submit-label (submit-label "Save")
                  #:before-save (before-save (lambda (r) 'done))
                  #:skip-save (skip-save #f)
                  #:stamp-user (stamp-user #f)
                  #:stamp-time (stamp-time #t)
                  #:stay-on-same-page (stay-on-same-page #f)
                  #:fail (fail (lambda (rec) #f))
                  #:validate (validate (lambda (rec) #f))
                  #:error-wrapper (error-wrapper default-error-wrapper)
                  #:error-msg (error-msg #f)
                  #:on-submit (on-submit #f) ; #f or a JS string
                  #:use-if-exists (use-if-exists #f)
                  #:skip-br (skip-br #f)
                  #:class (css-class #f)
                  #:auto-submit (auto-submit #f)
                  #:return-form-obj (return-form-obj #f)
                  #:input-id (input-id "none")
                  #:on-done (on-done (lambda (rec) (redirect-to (setting *WEB_APP_URL*)))))
  (let ((init-data (if (rec? init) (rec-data init) init))
        (is-upload (has-upload-field? fields)))
    ;; attempt to save the rec that's presumably in the request as generated by the form:
    (define (store-form-rec! req)
      (let* ((bindings (bindings/string req))
             ;; note that if a field is specified but not present in bindings,
             ;; it gets a #f assigned to it:
             (relevant-req-bindings
              (map (match-lambda ((list name label type)
                                  (cons name
                                        (field-value-lift (find-binding
                                                           (symbol->string name) bindings)
                                                          type))))
                   fields))
             (data (alist-merge init-data relevant-req-bindings))
             (a-rec (if (rec? init)
                        (update-edited-rec-with-merge! init data fields)
                        (fresh-rec-from-data data #:stamp-time stamp-time)))
             (the-rec (or (and use-if-exists
                               (load-one-where
                                `((,use-if-exists . ,(rec-prop a-rec use-if-exists)))))
                          a-rec)))
        (when stamp-user (rec-set-rec-prop! the-rec 'created-by stamp-user))
        (or (fail the-rec)
            (aand (validate the-rec)
                  (let ((form-meat (recur #:init (append relevant-req-bindings init)
                                          #:error-msg it)))
                    (error-wrapper (if (form-obj? form-meat)
                                       (form-markup form-meat)
                                       form-meat))))
            (begin (before-save the-rec)
                   (unless skip-save (store-rec! the-rec))
                   (let ((finally (on-done the-rec)))
                     (if stay-on-same-page
                         (e "feature missing")
                         finally))))))
    (let* ((form-id (number->string (random 1000000)))
           (f `(form
                ((action "/")
                 (id ,form-id)
                 ,@(splice-if css-class `(class ,css-class))
                 (method "post")
                 ;; XXX see this if pattern?
                 ,@(if is-upload '((enctype "multipart/form-data")) '())
                 ,@(if on-submit `((onsubmit ,on-submit)) '()))
                ,@(splice-if error-msg `(div ((class "errors")) ,error-msg))
                (input ((type "hidden")
                        (name ,(symbol->string (setting *CLOSURE_URL_KEY*)))
                        (value ,(body-as-closure-key (req) (store-form-rec! req)))))
                ,@(form-body fields submit-label init-data form-id input-id
                             #:skip-br skip-br #:auto-submit auto-submit))))
      (if return-form-obj (make-form-obj f form-id) f))))

(define form (make-recursive-keyword-version-of-fn form-aux "recur"))

;; we refresh the rec-to-edit in case, e.g., a comment has come in.
;; we only update the relevant fields too (so we don't, e.g., overwrite a comment
;; that came in in the meanwhile.)
(define (update-edited-rec-with-merge! rec-to-edit new-data fields)
  (let ((field-names (map first fields)))
    (rec-set-each-prop! (refresh rec-to-edit)
                        (filter (lambda (k.v) (memq (car k.v) field-names))
                                new-data))))

(define (has-upload-field? fields)
  (any (lambda (f) (eq? (last f) 'image)) fields))

;;
;; paint-field
;;
;; Note that field-value is a "lifted" (Scheme) value.
;;
(define (paint-field field-name field-type form-id
                     #:field-value (field-value #f)
                     #:auto-submit (auto-submit #f)
                     #:input-id (input-id #f))
  (let ((field-name (symbol->string field-name))
        (field-type-name (if (field-type? field-type)
                             (field-type-name field-type)
                             field-type))
        (auto '(onchange "this.form.submit();")))
    (case field-type-name
      ((text)
       `(input ((type "text") (id ,input-id) (name ,field-name) (class "text-input") (size "40")
                (value ,(or field-value "")))))
      ((long-text)
       `(textarea ((name ,field-name) (class "text-input")
                   (cols "20") (rows "4")) ,(or field-value "")))
      ((number)
       `(input ((type "text") (name ,field-name) (size "5") (class "text-input")
                (value ,(or (and field-value (number->string field-value)) "")))))
      ((password)
       `(input ((type "password") (class "text-input") (name ,field-name))))
      ((image)
       `(input ((type "file") (name ,field-name))))
      ((checkbox)
       (if field-value ; then it is checked
           `(span (input ((type "checkbox") (checked "yup") (name ,field-name)
                          (class "checkbox")
                          ,@(splice-if auto-submit auto)))
                  (input ((type "hidden") (name ,field-name) (value "off"))))
           `(input ((type "checkbox") (name ,field-name) (class "checkbox")
                    ,@(splice-if auto-submit auto)))))
      ((radio)
       (generic-picker (field-type-params field-type)
                       (lambda (val disp is-selected)
                         `(tr (td (input ((type "radio") (name ,field-name) (value ,val)
                                          ,@(if is-selected `((checked "yup")) '()))))
                              (td ,@disp)))
                       (lambda (elts) `(table ((class "big-radio")) ,@elts))
                       #:current-pick field-value))
      ((drop-down)
       `(group ,(generic-picker (field-type-params field-type)
                                (lambda (val disp is-selected)
                                  `(option ((value ,val)
                                            ,@(if is-selected `((selected "yup")) '()))
                                           ,disp))
                                (lambda (elts) `(select ((name ,field-name)) ,@elts))
                                #:current-pick field-value)
               (br)))
      (else (error (format "Field type '~A' for field '~A' not understood."
                           field-type field-name))))))

;; elt-wrapper : val-str X display X is-selected -> content
;; whole-wrapper : list(elt-content) -> content
(define (generic-picker sym.=>display elt-wrapper whole-wrapper
                        #:current-pick (current-pick #f))
  (whole-wrapper (map (match-lambda ((list-rest sym disp)
                                     (elt-wrapper (symbol->string sym)
                                                  disp
                                                  (eq? sym current-pick))))
                      sym.=>display)))

;; go from form value to Scheme value
(define (field-value-lift field-val field-type)
  (cond
   ;; checkbox?
   ((and (equal? field-type 'checkbox) (binding/string:form? field-val))
    (if (equal? (binding/string:form-value field-val) "on") #t #f))
   ;; number?
   ((and (equal? field-type 'number) (binding/string:form? field-val))
    (string->number (binding/string:form-value field-val)))
   ;; image?
   ((and (equal? field-type 'image) (binding/string:file? field-val))
    (save-uploaded-file-and-return-filename! field-val))
   ;; else
   (else (if (and (binding/string:form? field-val)
                  (string=? (binding/string:form-value field-val) ""))
             #f
             (binding/string:form-value field-val)))))

(define (paint-rich-text-editor field-name field-value form-id)
  `(div ((class "yui-skin-sam"))
        (textarea ((name ,field-name) (id ,field-name) (cols "50") (rows "10"))
                  ,field-value)
        (script ,(format "render_rich_text_editor('~A', '~A')" field-name form-id))))

;; returns a list of html objects, so you'll need to splice in to the caller.
(define (form-body fields submit-label init-data form-id input-id
                   #:skip-br (skip-br #f) #:auto-submit (auto-submit #f))
  (define (paint-segment field-name display-name field-type)
    (let* ((is-checkbox (eq? field-type 'checkbox))
           (lbl-inp-lst (list (if is-checkbox
                                  display-name
                                  `(label ,display-name))
                              (paint-field field-name field-type form-id
                                           #:field-value (assoc-val field-name init-data)
                                           #:input-id input-id
                                           #:auto-submit auto-submit)
                              (if skip-br "" '(br)))))
      ;; we want the checkbox to come before the label:
      (when (and is-checkbox display-name (or (not (string? display-name))
                                              (not (string=? display-name ""))))
        (set! lbl-inp-lst (cons-to-end '(br) (reverse lbl-inp-lst))))
      `(group ,@lbl-inp-lst)))
  (append
   (map (match-lambda ((list field-name display-name field-type)
                       (paint-segment field-name display-name field-type)))
        fields)
   `((input ((type "submit") (value ,submit-label))))))

(define-struct field-type (name params))

(define (default-error-wrapper form-meat)
  form-meat)
