;;; devdocs.el --- Emacs viewer for DevDocs -*- lexical-binding: t -*-

;; Copyright (C) 2021  Free Software Foundation, Inc.

;; Author: Augusto Stoffel <arstoffel@gmail.com>
;; Keywords: help
;; URL: https://github.com/astoff/devdocs
;; Package-Requires: ((emacs "27.1"))
;; Version: 0.1

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; devdocs is a documentation viewer similar to Emacs's built-in Info
;; browser, but geared towards documentation obtained from
;; https://devdocs.io.

;; To get started, download some documentation with `devdocs-install`.
;; This will show the available documents and save the selected one to
;; disk.  Once you have the desired documents at hand, use
;; `devdocs-lookup` to search for entries.

;;; Code:

(require 'seq)
(require 'shr)
(eval-when-compile
  (require 'let-alist))

(defgroup devdocs nil
  "Emacs viewer for DevDocs."
  :group 'help
  :prefix "devdocs-")

(defcustom devdocs-current-docs nil
  "A list of documents relevant to the current buffer."
  :local t
  :type '(list string))

(defcustom devdocs-data-dir (expand-file-name "devdocs" user-emacs-directory)
  "Directory to save documentation files."
  :type 'directory)

(defvar devdocs-site-url "https://devdocs.io"
  "Location of the DevDocs website.")

(defvar devdocs-cdn-url "https://documents.devdocs.io"
  "Location of the DevDocs CDN.")

(defcustom devdocs-timeout 300
  "Number of seconds to keep cached document indexes."
  :type 'number)

(defcustom devdocs-separator " » "
  "String used to format a documentation location, e.g. in header line."
  :type 'string)

(defvar devdocs--index (make-hash-table :test 'equal)
  "A hash table to cache document indices.
To be accessed through the function `devdocs--index'.")

(defvar devdocs-history nil
  "History of documentation entries.")

;;; Documentation management

(defvar devdocs--doc-metadata (make-hash-table :test 'equal)
  "A hash table mapping document slugs to their metadata.
To be accessed through the function `devdocs--doc-metadata'.")

(defun devdocs--doc-metadata (doc &optional refresh)
  "Return the metadata for a document DOC.
Also populates the variable `devdocs--doc-metadata' if necessary,
either from data on disk if REFRESH is nil, or from freshly
downloaded data otherwise."
  (when (or refresh (hash-table-empty-p devdocs--doc-metadata))
    (let* ((file (expand-file-name "docs.json" devdocs-data-dir))
           (docs (if (or refresh (not (file-exists-p file)))
                     (with-temp-file file
                       (make-directory (file-name-directory file) t)
                       (url-insert-file-contents (format "%s/docs.json" devdocs-site-url))
                       (json-read))
                   (json-read-file file))))
      (clrhash devdocs--doc-metadata)
      (seq-doseq (doc docs)
        (puthash (alist-get 'slug doc) doc devdocs--doc-metadata))))
  (gethash doc devdocs--doc-metadata))

(defun devdocs--doc-title (doc)
  "Title of document with slug DOC."
  (let-alist (devdocs--doc-metadata doc)
    (if .version (concat .name " " .version) .name)))

(defun devdocs--read-document (prompt &optional predicate multiple refresh)
  "Query interactively for a DevDocs document.
PROMPT and PREDICATE as `completing-read'.
MULTIPLE, if non-nil, allows selecting multiple documents.
REFRESH, if non-nil, downloads the DevDocs document list anew."
  (devdocs--doc-metadata nil refresh) ;; Maybe initialize and refresh
  (let (cands)
    (maphash (lambda (k _)
               (when (or (not predicate) (funcall predicate k))
                 (push (cons (devdocs--doc-title k) k) cands)))
             devdocs--doc-metadata)
    (unless cands (user-error "No documents"))
    (if multiple
        (delq nil (mapcar (lambda (s) (cdr (assoc s cands)))
                          (completing-read-multiple prompt cands)))
      (cdr (assoc (completing-read prompt cands nil t) cands)))))

(defun devdocs--installed-p (doc)
  "Non-nil if DOC is installed."
  (file-exists-p
   (expand-file-name "metadata" (expand-file-name doc devdocs-data-dir))))

;;;###autoload
(defun devdocs-delete (doc)
  "Delete DevDocs documentation.
DOC is a document slug."
  (interactive (list (devdocs--read-document "Delete documentation: "
                                            #'devdocs--installed-p)))
  (let ((dest (file-name-as-directory
               (expand-file-name doc devdocs-data-dir))))
    (if (and (file-directory-p dest)
             (file-in-directory-p dest devdocs-data-dir))
        (delete-directory dest t t)
      (user-error (format "Documentation for `%s' is not installed" doc)))))

;;;###autoload
(defun devdocs-install (doc)
  "Download and install DevDocs documentation.
DOC is a document slug."
  (interactive (list (devdocs--read-document
                      "Install documentation: "
                      (lambda (s) (not (devdocs--installed-p s)))
                      nil 'refresh)))
  (let ((temp (make-temp-file "devdocs-" t)))
    (with-temp-buffer
      (url-insert-file-contents (format "%s/%s/db.json" devdocs-cdn-url doc))
      (seq-doseq (entry (json-read))
        (with-temp-file (expand-file-name
                         (url-hexify-string (format "%s.html" (car entry))) temp)
          (insert (cdr entry)))))
    (url-copy-file (format "%s/%s/index.json" devdocs-cdn-url doc)
                   (expand-file-name "index.json" temp))
    (with-temp-file (expand-file-name "metadata" temp)
      (prin1 (devdocs--doc-metadata doc) (current-buffer)))
    (rename-file temp (expand-file-name doc devdocs-data-dir) t)
    (clrhash devdocs--index)
    (message "Installed %s documentation" (devdocs--doc-title doc))))

;;; Document indexes

(defun devdocs--index (doc)
  "Return the index of document DOC.
This is an alist containing `entries' and `types'."
  (if-let ((idx (gethash doc devdocs--index)))
      (prog1 idx
        (timer-set-time (alist-get 'timer idx) devdocs-timeout))
    (let* ((docid (cons 'doc doc))
           (idx (json-read-file (expand-file-name (concat doc "/index.json")
                                                  devdocs-data-dir)))
           (entries (alist-get 'entries idx)))
      (setf (alist-get 'timer idx)
            (run-at-time devdocs-timeout nil
                         (lambda () (remhash doc devdocs--index))))
      (seq-do-indexed (lambda (entry i)
                        (push `(index . ,i) entry)
                        (push docid entry)
                        (aset entries i entry))
                      entries)
      (puthash doc idx devdocs--index))))

;;; Documentation viewer

(defvar-local devdocs--stack nil
  "List of viewed entries, set buffer-locally when in `devdocs-mode'.")

(defvar-local devdocs--forward-stack nil
  "List of viewed entries for `devdocs-go-forward'.")

(defvar devdocs-header-line
  '(:eval (let-alist (car devdocs--stack)
            (concat (devdocs--doc-title .doc)
                    devdocs-separator .type
                    devdocs-separator .name))))

(define-derived-mode devdocs-mode special-mode "DevDocs"
  "Major mode for viewing DevDocs documents."
  (setq-local browse-url-browser-function
              (cons '("\\`[^:]*\\'" . devdocs--browse-url)
                    (if (functionp browse-url-browser-function)
                        `(("." . ,browse-url-browser-function))
                      browse-url-browser-function)))
  (setq buffer-undo-list t
        header-line-format devdocs-header-line
        truncate-lines t))

(defun devdocs-goto-target ()
  "Go to the original position in a DevDocs buffer."
  (interactive)
  (goto-char (point-min))
  (text-property-search-forward 'shr-target-id)
  (beginning-of-line))

(defun devdocs-go-back ()
  "Go to the previously displayed entry in this DevDocs buffer."
  (interactive)
  (unless (cadr devdocs--stack)
    (user-error "No previous entry"))
  (push (pop devdocs--stack) devdocs--forward-stack)
  (devdocs--render (pop devdocs--stack)))

(defun devdocs-go-forward ()
  "Go to the next entry in this DevDocs buffer."
  (interactive)
  (unless (car devdocs--forward-stack)
    (user-error "No next entry"))
  (devdocs--render (pop devdocs--forward-stack)))

(let ((map devdocs-mode-map))
  (define-key map [tab] 'forward-button)
  (define-key map [backtab] 'backward-button)
  (define-key map "l" 'devdocs-go-back)
  (define-key map "r" 'devdocs-go-forward)
  (define-key map "." 'devdocs-goto-target))

;;; Rendering

(defun devdocs--path-file (path)
  "Return the non-fragment part of PATH."
  (substring path 0 (string-match "#" path)))

(defun devdocs--path-fragment (path)
  "Return the fragment part of PATH, or nil if absent."
  (when-let ((i (string-match "#" path)))
    (substring path (1+ i))))

(defun devdocs--path-expand (path base)
  "Expand PATH relative to a BASE path."
  (pcase (string-to-char path)
    ('?/ path)
    ('?# (concat (devdocs--path-file base) path))
    (_ (concat (file-name-directory base) path))))

(defun devdocs--render (entry)
  "Render a DevDocs documentation entry, returning a buffer.

ENTRY is an alist like those in the variable `devdocs--index',
possibly with an additional ENTRY.fragment which overrides the
fragment part of ENTRY.path."
  (or (libxml-available-p)
      (error "This function requires Emacs to be compiled with libxml2"))
  (with-current-buffer (get-buffer-create "*devdocs*")
    (unless (eq major-mode 'devdocs-mode)
      (devdocs-mode))
    (let-alist entry
      (let ((shr-target-id (or .fragment (devdocs--path-fragment .path)))
            (buffer-read-only nil)
            (file (expand-file-name (format "%s/%s.html" .doc (url-hexify-string
                                                               (devdocs--path-file .path)))
                                    devdocs-data-dir)))
        (erase-buffer)
        ;; TODO: cl-progv here for shr settings?
        (shr-insert-document
         (with-temp-buffer
           (insert-file-contents file)
           (libxml-parse-html-region (point-min) (point-max)))))
      (set-buffer-modified-p nil)
      (setq-local devdocs-current-docs (list .doc))
      (push entry devdocs--stack)
      (devdocs-goto-target)
      (current-buffer))))

(defun devdocs--browse-url (url &rest _)
  "A suitable `browse-url-browser-function' for `devdocs-mode'.
URL can be an internal link in a DevDocs document."
  (let-alist (car devdocs--stack)
    (let* ((dest (devdocs--path-expand url .path))
           (file (devdocs--path-file dest))
           (frag (devdocs--path-fragment dest))
           (entry (seq-some (lambda (it)
                              (when (let-alist it
                                      (or (string= .path dest)
                                          (string= .path file)))
                                it))
                            (alist-get 'entries (devdocs--index .doc)))))
      (unless entry (error "Can't find `%s'" dest))
      (when frag (push `(fragment . ,frag) entry))
      (devdocs--render entry))))

;;; Lookup command

(defun devdocs--entries (doc)
  "A list of entries in DOC, as propertized strings."
  (seq-map (lambda (it)
             (let ((s (let-alist it
                        ;; Disambiguation cookie for entries with same .name
                        (format #("%s\0%c%s" 2 7 (invisible t))
                                .name .index .doc))))
               (prog1 s (put-text-property 0 1 'devdocs--data it s))))
           (alist-get 'entries (devdocs--index doc))))

(defun devdocs--get-data (str)
  "Get data stored as a string property in STR."
  (get-text-property 0 'devdocs--data str))

(defun devdocs--annotate (cand)
  "Return an annotation for `devdocs--read-entry' candidate CAND."
  (let-alist (devdocs--get-data cand)
    (concat " " (propertize " " 'display '(space :align-to 40))
     (devdocs--doc-title .doc) devdocs-separator .type)))

(defun devdocs--eat-cookie (&rest _)
  "Eat the disambiguation cookie in the minibuffer."
  (let* ((pos (minibuffer-prompt-end))
         (max (point-max)))
    (while (and (< pos max) (/= 0 (char-after pos)))
      (setq pos (1+ pos)))
    (add-text-properties pos max '(invisible t rear-nonsticky t cursor-intangible t))))

(defun devdocs--read-entry (prompt)
  "Read the name of an entry in a document, using PROMPT.
All entries of `devdocs-current-docs' are listed."
  (let* ((cands (mapcan #'devdocs--entries devdocs-current-docs))
         (metadata '(metadata
                     (category . devdocs)
                     (annotation-function . devdocs--annotate)))
         (coll (lambda (string predicate action)
                 (if (eq action 'metadata)
                     metadata
                   (complete-with-action action cands string predicate))))
         (cand (minibuffer-with-setup-hook
                   (lambda ()
                     (add-hook 'after-change-functions 'devdocs--eat-cookie nil t))
                   (completing-read prompt coll nil t nil
                                    'devdocs-history
                                    (thing-at-point 'symbol)))))
    (devdocs--get-data (car (member cand cands)))))

;;;###autoload
(defun devdocs-lookup (&optional ask-docs)
  "Look up a DevDocs documentation entry.

Display entries in the documents `devdocs-current-docs' for
selection.  With a prefix argument (or, from Lisp, if ASK-DOCS is
non-nil), first read a list of available documents and set
`devdocs-current-docs' for this buffer."
  (interactive "P")
  (when (or ask-docs (not devdocs-current-docs))
    (setq-local devdocs-current-docs (devdocs--read-document
                                     "Docs for this buffer: "
                                     #'devdocs--installed-p t)))
  (let* ((entry (devdocs--read-entry "Go to documentation: "))
         (buffer (devdocs--render entry)))
    (with-selected-window (display-buffer buffer)
      (devdocs-goto-target)
      (recenter 0))))

;;; Compatibility with the old devdocs package

;;;###autoload
(defun devdocs-search (query)
  "Search for QUERY in the DevDocs website."
  (interactive (list (read-from-minibuffer
                      (format "Search %s: " devdocs-site-url)
                      nil nil nil nil (thing-at-point 'symbol))))
  (browse-url (format "%s/#q=%s" devdocs-site-url (url-hexify-string query))))

(provide 'devdocs)
;;; devdocs.el ends here
