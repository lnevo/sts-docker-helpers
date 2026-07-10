/**
 * Shared workflow editor UI — inline rows, catalog dropdowns, category colors.
 */
(function (global) {
  'use strict';

  const WorkflowUI = {
    API: 'operational_steps_api.php',
    catalog: { adder_functions: [], functions: [], adder_categories: {} },
    catalogMap: {},
    dynamicOptions: {},
    recipe: { version: 1, name: 'workflow', steps: [] },
    compiledSteps: [],
    runOptions: {},
    dragIndex: null,
    insertMode: 'beginning',
    insertStepNum: 1,
    insertAtIndex: 0,

    el(id) { return document.getElementById(id); },

    escapeHtml(s) {
      return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
    },

    async api(action, method, body) {
      const opts = { method: method || 'GET', cache: 'no-store' };
      if (body) {
        opts.method = 'POST';
        opts.headers = { 'Content-Type': 'application/json' };
        opts.body = JSON.stringify(Object.assign({ action: action }, body));
      }
      const url = body ? this.API : this.API + '?action=' + encodeURIComponent(action) + '&t=' + Date.now();
      const res = await fetch(url, opts);
      const data = await res.json();
      if (!res.ok || !data.ok) throw new Error(data.error || 'Request failed');
      return data;
    },

    setStatus(msg, kind) {
      const node = this.el('status');
      if (!node) return;
      node.textContent = msg;
      node.className = 'status ' + (kind || 'info');
    },

    log(msg) {
      const node = this.el('log');
      if (!node) return;
      node.textContent = typeof msg === 'string' ? msg : JSON.stringify(msg, null, 2);
    },

    buildCatalogMap() {
      this.catalogMap = {};
      (this.catalog.functions || []).concat(this.catalog.adder_functions || []).forEach((f) => {
        this.catalogMap[f.id] = f;
      });
    },

    stepColorClass(step) {
      const def = this.catalogMap[step.function];
      const group = def?.adder_group || '';
      const cat = def?.category || '';
      if (['before', 'during', 'after'].includes(group) || cat === 'operations') return 'cat-operations';
      if (group === 'database' || cat === 'database') return 'cat-database';
      if (group === 'reports' || group === 'waybills' || cat === 'reports') return 'cat-reports';
      return 'cat-neutral';
    },

    isDatabaseStep(step) {
      const def = this.catalogMap[step?.function];
      const group = def?.adder_group || '';
      const cat = def?.category || '';
      return group === 'database' || cat === 'database';
    },

    stsLinkHtml(step) {
      if (!step?.function || this.isDatabaseStep(step)) return '';
      const def = this.catalogMap[step.function];
      if (!def?.gui_path) return '';
      return '<a class="gui-link hdr-gui-link" href="' + this.escapeHtml(def.gui_path) +
        '" target="_blank" rel="noopener">STS</a>';
    },

    catalogGroups() {
      const cats = this.catalog.adder_categories || {};
      const byGroup = {};
      Object.values(this.catalogMap).forEach((f) => {
        const g = f.adder_group || f.category || 'other';
        (byGroup[g] = byGroup[g] || []).push(f);
      });
      Object.keys(byGroup).forEach((g) => {
        byGroup[g].sort((a, b) => (a.label || a.id).localeCompare(b.label || b.id));
      });
      const order = Object.keys(cats).length ? Object.keys(cats) : Object.keys(byGroup);
      return { order, byGroup, cats };
    },

    commandSelectHtml(selectedId, rowIdx) {
      const adder = this.catalog.adder_functions || [];
      const cats = this.catalog.adder_categories || {};
      const byGroup = {};
      adder.forEach((f) => {
        const g = f.adder_group || 'during';
        (byGroup[g] = byGroup[g] || []).push(f);
      });
      const order = Object.keys(cats).length ? Object.keys(cats) : Object.keys(byGroup);
      let html = '<select class="row-fn field-select" data-fn-select data-row="' + rowIdx + '">';
      const hasSelection = selectedId && this.catalogMap[selectedId];
      html += '<option value=""' + (!hasSelection ? ' selected' : '') + '>-- Select a command --</option>';
      order.forEach((g) => {
        const items = byGroup[g] || [];
        if (!items.length) return;
        const groupDisabled = g === 'reports';
        html += '<optgroup label="' + this.escapeHtml(cats[g] || g) + '"' + (groupDisabled ? ' disabled' : '') + '>';
        items.forEach((f) => {
          const dis = groupDisabled || f.disabled;
          html += '<option value="' + f.id + '"' +
            (f.id === selectedId ? ' selected' : '') +
            (dis ? ' disabled' : '') + '>' +
            this.escapeHtml(f.label || f.id) + '</option>';
        });
        html += '</optgroup>';
      });
      if (selectedId && !adder.some((f) => f.id === selectedId)) {
        const def = this.catalogMap[selectedId];
        html += '<optgroup label="Legacy / imported">';
        html += '<option value="' + this.escapeHtml(selectedId) + '" selected>' +
          this.escapeHtml(def?.label || selectedId) + '</option></optgroup>';
      }
      html += '</select>';
      return html;
    },

    optionsForParam(p) {
      const from = p.options_from || p.type;
      const d = this.dynamicOptions;
      if (p.type === 'select' && p.options) return p.options.map((o) => ({ value: o, label: o }));
      if (from === 'jobs') return (d.jobs || []).map((j) => ({ value: j.name, label: j.name }));
      if (from === 'shipments') return (d.shipments || []).map((s) => ({ value: s.code, label: s.label }));
      if (from === 'car_codes') return (d.car_codes || []).map((c) => ({ value: c.code, label: c.label }));
      if (from === 'commodities') return (d.commodities || []).map((c) => ({ value: c.code, label: c.label }));
      if (from === 'locations') return (d.locations || []).map((l) => ({ value: l.code || l.label, label: l.label }));
      if (from === 'setout_locations') return d.setout_locations || [];
      if (from === 'scopes') return d.scopes || [];
      if (from === 'backups') return (d.backups || []).map((b) => ({ value: b, label: b }));
      return [];
    },

    inlineParamFieldHtml(p, val, rowIdx) {
      const id = 'r' + rowIdx + '-' + p.key;
      const lbl = '<span class="inline-lbl">' + this.escapeHtml(p.label) + '</span>';
      const opts = this.optionsForParam(p);
      val = val != null ? val : (p.default != null ? p.default : '');

      if (p.type === 'select' && p.options) {
        let h = '<label class="inline-field">' + lbl + '<select class="field-select" data-param="' + p.key + '" id="' + id + '">';
        p.options.forEach((o) => {
          h += '<option value="' + this.escapeHtml(o) + '"' + (String(val) === String(o) ? ' selected' : '') + '>' +
            this.escapeHtml(o) + '</option>';
        });
        return h + '</select></label>';
      }
      if (['job', 'location', 'backup', 'scope', 'setout_location', 'shipment', 'car_code', 'commodity'].includes(p.type) || opts.length) {
        const allowCustom = p.type !== 'backup' && p.allow_custom !== false;
        let h = '<label class="inline-field">' + lbl + '<select class="field-select" data-param="' + p.key + '" id="' + id + '">';
        if (allowCustom) h += '<option value="">—</option>';
        opts.forEach((o) => {
          const v = o.value != null ? o.value : o;
          const l = o.label != null ? o.label : o;
          h += '<option value="' + this.escapeHtml(String(v)) + '"' + (String(val) === String(v) ? ' selected' : '') + '>' +
            this.escapeHtml(String(l)) + '</option>';
        });
        if (val && !opts.some((o) => String(o.value || o) === String(val))) {
          h += '<option value="' + this.escapeHtml(String(val)) + '" selected>' + this.escapeHtml(String(val)) + '</option>';
        }
        return h + '</select></label>';
      }
      if (p.type === 'number') {
        return '<label class="inline-field">' + lbl +
          '<input type="number" class="field-input" data-param="' + p.key + '" id="' + id + '" value="' +
          this.escapeHtml(String(val)) + '"></label>';
      }
      return '<label class="inline-field">' + lbl +
        '<input type="text" class="field-input" data-param="' + p.key + '" id="' + id + '" value="' +
        this.escapeHtml(String(val)) + '"></label>';
    },

    shouldHideInlineParam(step, p) {
      if (!step || !p) return false;
      if (step.function === 'section_label' && p.key === 'remarks') return true;
      if (step.function === 'marker' && p.key === 'note') return true;
      return false;
    },

    rowRemarksText(step) {
      if (!step) return '';
      if (step.function === 'section_label') {
        return step.description || step.params?.remarks || '';
      }
      if (step.function === 'marker') {
        return step.description || step.params?.note || '';
      }
      return step.description || '';
    },

    paramsHtmlForStep(step, rowIdx) {
      if (!step?.function) {
        return '<span class="inline-empty">Select a command</span>';
      }
      const def = this.catalogMap[step.function];
      if (!def || !def.params || !def.params.length) {
        return '<span class="inline-empty">No parameters</span>';
      }
      const values = step.params || {};
      const fields = def.params
        .filter((p) => !this.shouldHideInlineParam(step, p))
        .map((p) => this.inlineParamFieldHtml(p, values[p.key], rowIdx));
      return fields.length ? fields.join('') : '<span class="inline-empty">No parameters</span>';
    },

    readParamsFromRow(row) {
      const params = {};
      row.querySelectorAll('[data-param]').forEach((node) => {
        params[node.getAttribute('data-param')] = node.value;
      });
      row.querySelectorAll('[data-param-custom]').forEach((node) => {
        const k = node.getAttribute('data-param-custom');
        if (node.value.trim() !== '') params[k] = node.value.trim();
      });
      return params;
    },

    syncStepFromRow(row, idx) {
      const fn = row.querySelector('[data-fn-select]')?.value || this.recipe.steps[idx]?.function || '';
      const desc = row.querySelector('[data-notes]')?.value?.trim() || '';
      const step = { function: fn, params: this.readParamsFromRow(row) };
      if (desc) step.description = desc;
      if (fn === 'section_label' && step.params.remarks !== undefined) {
        delete step.params.remarks;
      }
      this.recipe.steps[idx] = step;
      return step;
    },

    syncAllStepsFromDom() {
      const list = this.el('steps-list');
      if (!list) return;
      list.querySelectorAll('.step-row[data-idx]').forEach((row) => {
        const idx = parseInt(row.dataset.idx, 10);
        if (!isNaN(idx)) this.syncStepFromRow(row, idx);
      });
    },

    blankStep() {
      return {
        function: '',
        params: {},
        description: '',
      };
    },

    readInsertFromDom() {
      const mode = this.el('insert-mode')?.value || 'beginning';
      const num = parseInt(this.el('insert-step-num')?.value, 10) || 1;
      this.insertMode = mode;
      this.insertStepNum = num;
      this.insertAtIndex = this.resolveInsertIndex();
    },

    resolveInsertIndex() {
      const n = this.recipe.steps.length;
      const num = Math.max(1, this.insertStepNum || 1);
      switch (this.insertMode) {
        case 'beginning':
          return 0;
        case 'end':
          return n;
        case 'before':
          return Math.min(Math.max(0, num - 1), n);
        case 'after':
          return Math.min(num, n);
        default:
          return 0;
      }
    },

    syncInsertFromDom() {
      this.readInsertFromDom();
      this.highlightInsertTarget();
    },

    syncInsertUi() {
      const wrap = this.el('insert-step-num-wrap');
      const numInput = this.el('insert-step-num');
      const modeSel = this.el('insert-mode');
      if (!wrap || !numInput || !modeSel) return;
      const mode = modeSel.value || 'beginning';
      this.insertMode = mode;
      const needsNum = mode === 'before' || mode === 'after';
      wrap.hidden = !needsNum;
      const n = this.recipe.steps.length;
      numInput.max = String(Math.max(1, n));
      if (needsNum) {
        this.insertStepNum = Math.max(1, Math.min(this.insertStepNum || 1, Math.max(1, n)));
        numInput.value = String(this.insertStepNum);
      }
      this.insertAtIndex = this.resolveInsertIndex();
      this.highlightInsertTarget();
    },

    setInsertBefore(stepNum) {
      const modeSel = this.el('insert-mode');
      const numInput = this.el('insert-step-num');
      if (modeSel) modeSel.value = 'before';
      this.insertMode = 'before';
      this.insertStepNum = stepNum;
      if (numInput) numInput.value = String(stepNum);
      this.syncInsertUi();
    },

    highlightInsertTarget() {
      const list = this.el('steps-list');
      if (!list) return;
      list.querySelectorAll('.step-row.insert-marker').forEach((n) => n.classList.remove('insert-marker'));
      const marker = list.querySelector('.step-row[data-idx="' + this.insertAtIndex + '"]');
      if (marker) marker.classList.add('insert-marker');
    },

    remarksExpandedClass(step) {
      return this.rowRemarksText(step).trim() ? ' row-top-remarks-expanded' : '';
    },

    updateRemarksLayout(row) {
      const input = row.querySelector('[data-notes]');
      const top = row.querySelector('.row-top');
      if (!input || !top) return;
      top.classList.toggle('row-top-remarks-expanded', input.value.trim().length > 0);
    },

    stepRowInnerHtml(step, idx) {
      const rowKey = idx;

      return (
        '<div class="row-top' + this.remarksExpandedClass(step) + '">' +
          '<span class="handle" title="Drag to reorder">⋮⋮</span>' +
          '<span class="step-num">' + (idx + 1) + '</span>' +
          '<button type="button" class="btn-icon btn-insert-before" title="Insert before step ' + (idx + 1) + '">+</button>' +
          '<label class="inline-field row-command">' +
            '<span class="inline-lbl">Command</span>' +
            this.commandSelectHtml(step.function, rowKey) +
          '</label>' +
          '<div class="row-params">' + this.paramsHtmlForStep(step, rowKey) + '</div>' +
          '<label class="inline-field row-remarks">' +
            '<span class="inline-lbl">Remarks</span>' +
            '<input type="text" class="field-input field-remarks" data-notes placeholder="Optional remarks" value="' +
            this.escapeHtml(this.rowRemarksText(step)) + '">' +
          '</label>' +
          '<div class="row-sts hdr-sts-cell" data-sts-cell>' + this.stsLinkHtml(step) + '</div>' +
          '<button type="button" class="btn-icon btn-del" title="Delete">×</button>' +
        '</div>' +
        '<div class="row-bottom">' +
          '<div class="step-preview">' + this.previewHtml(step, idx) + '</div>' +
        '</div>'
      );
    },

    updateRowStsLink(row, step) {
      const cell = row.querySelector('[data-sts-cell]');
      if (cell) cell.innerHTML = this.stsLinkHtml(step);
    },

    defaultParamsForFunction(fid, oldParams) {
      const def = this.catalogMap[fid];
      const params = {};
      oldParams = oldParams || {};
      (def?.params || []).forEach((p) => {
        const k = p.key;
        if (oldParams[k] !== undefined && oldParams[k] !== '') {
          params[k] = oldParams[k];
        } else if (p.default !== undefined && p.default !== '') {
          params[k] = p.default;
        } else {
          params[k] = '';
        }
      });
      return params;
    },

    compileOne(step, idx) {
      const def = this.catalogMap[step.function];
      let title = '';
      if (def) {
        let t = def.gui_template || def.label || '';
        const p = step.params || {};
        if (step.function === 'pick_up_cars') {
          t = t.replace('{location_suffix}', p.location ? p.location : '');
        }
        title = t.replace(/\{(\w+)\}/g, (_, k) => (p[k] != null && p[k] !== '' ? String(p[k]) : '')).replace(/\s+/g, ' ').trim();
      }
      if (!title && step.instruction) title = String(step.instruction).trim();
      if (!title && step.params?.label) title = String(step.params.label).trim();
      if (!title && step.function) title = step.function.replace(/_/g, ' ');
      if (!title && idx != null) title = 'Step ' + (idx + 1);
      return title || '?';
    },

    previewHtml(step, idx) {
      if (!step?.function) {
        return '<span class="preview-fallback">-- Select a command --</span>';
      }
      const def = this.catalogMap[step.function];
      if (step.function === 'section_label') {
        const label = step.params?.label || def?.label || 'Section label';
        let html = '<span class="preview-cmd">' + this.escapeHtml(label) + '</span>';
        const remarks = this.rowRemarksText(step);
        if (remarks) {
          html += '<span class="preview-remarks">' + this.escapeHtml(remarks) + '</span>';
        }
        return html;
      }
      const cmd = def?.label || (step.function || '').replace(/_/g, ' ');
      let html = '<span class="preview-cmd">' + this.escapeHtml(cmd) + '</span>';
      const params = step.params || {};
      const pdefs = def?.params || [];
      let pi = 0;
      pdefs.forEach((p) => {
        if (this.shouldHideInlineParam(step, p)) return;
        const val = params[p.key];
        if (val !== undefined && String(val).trim() !== '') {
          html += '<span class="preview-param p-' + (pi % 5) + '" title="' + this.escapeHtml(p.label) + '">' +
            this.escapeHtml(String(val)) + '</span>';
          pi++;
        }
      });
      if (pi === 0) {
        const compiled = this.compileOne(step, idx);
        if (compiled && compiled !== cmd) {
          html += '<span class="preview-fallback">' + this.escapeHtml(compiled) + '</span>';
        }
      }
      return html;
    },

    updateRowPreview(row, idx) {
      const step = this.recipe.steps[idx];
      if (!step) return;
      const preview = row.querySelector('.step-preview');
      if (preview) preview.innerHTML = this.previewHtml(step, idx);
    },

    refreshRowParams(idx) {
      const list = this.el('steps-list');
      const row = list?.querySelector('.step-row[data-idx="' + idx + '"]');
      if (!row) return;
      const step = this.recipe.steps[idx];
      const paramsEl = row.querySelector('.row-params');
      if (paramsEl) paramsEl.innerHTML = this.paramsHtmlForStep(step, idx);
      row.className = 'step-row ' + this.stepColorClass(step);
      this.updateRowStsLink(row, step);
      this.updateRowPreview(row, idx);
    },

    bindRowEvents(row, idx) {
      row.querySelector('[data-fn-select]')?.addEventListener('change', (e) => {
        const newFn = e.target.value;
        this.syncStepFromRow(row, idx);
        this.recipe.steps[idx].function = newFn;
        this.recipe.steps[idx].params = newFn
          ? this.defaultParamsForFunction(newFn, this.recipe.steps[idx].params)
          : {};
        this.refreshRowParams(idx);
        const updatedRow = this.el('steps-list')?.querySelector('.step-row[data-idx="' + idx + '"]');
        if (updatedRow) {
          updatedRow.className = 'step-row ' + this.stepColorClass(this.recipe.steps[idx]);
          this.updateRowStsLink(updatedRow, this.recipe.steps[idx]);
        }
        this.setStatus(
          newFn ? ('Step ' + (idx + 1) + ': ' + (this.catalogMap[newFn]?.label || newFn)) : ('Step ' + (idx + 1) + ': pick a command'),
          'info'
        );
      });

      row.querySelector('.btn-del')?.addEventListener('click', () => {
        if (!confirm('Delete step ' + (idx + 1) + '?')) return;
        this.syncAllStepsFromDom();
        this.recipe.steps.splice(idx, 1);
        this.renderSteps({ skipSync: true, preserveScroll: true });
        this.setStatus('Deleted step', 'ok');
      });

      row.querySelector('.btn-insert-before')?.addEventListener('click', () => {
        this.setInsertBefore(idx + 1);
        this.setStatus('Will insert before step ' + (idx + 1), 'info');
      });

      const onRowEdit = () => {
        this.syncStepFromRow(row, idx);
        row.className = 'step-row ' + this.stepColorClass(this.recipe.steps[idx]);
        this.updateRemarksLayout(row);
        this.updateRowPreview(row, idx);
      };
      row.addEventListener('change', onRowEdit);
      row.addEventListener('input', onRowEdit);
      this.updateRemarksLayout(row);

      row.querySelector('.handle')?.addEventListener('mousedown', (e) => e.stopPropagation());

      row.addEventListener('dragstart', (e) => {
        if (e.target.closest('select, input, button')) { e.preventDefault(); return; }
        this.syncAllStepsFromDom();
        this.dragIndex = idx;
        row.classList.add('dragging');
      });
      row.addEventListener('dragend', () => {
        row.classList.remove('dragging');
        this.dragIndex = null;
        this.el('steps-list')?.querySelectorAll('.drag-over').forEach((n) => n.classList.remove('drag-over'));
      });
      row.addEventListener('dragover', (e) => {
        e.preventDefault();
        if (this.dragIndex !== null && this.dragIndex !== idx) row.classList.add('drag-over');
      });
      row.addEventListener('dragleave', () => row.classList.remove('drag-over'));
      row.addEventListener('drop', (e) => {
        e.preventDefault();
        row.classList.remove('drag-over');
        if (this.dragIndex === null || this.dragIndex === idx) return;
        const moved = this.recipe.steps.splice(this.dragIndex, 1)[0];
        this.recipe.steps.splice(idx, 0, moved);
        this.renderSteps({ preserveScroll: true });
      });
    },

    renderSteps(options) {
      options = options || {};
      const scrollY = options.preserveScroll ? window.scrollY : null;

      if (!options.skipSync) {
        this.syncAllStepsFromDom();
      }

      const list = this.el('steps-list');
      if (!list) return;
      list.innerHTML = '';

      this.recipe.steps.forEach((step, idx) => {
        const row = document.createElement('div');
        row.className = 'step-row ' + this.stepColorClass(step);
        row.draggable = true;
        row.dataset.idx = String(idx);
        row.innerHTML = this.stepRowInnerHtml(step, idx);
        this.bindRowEvents(row, idx);
        list.appendChild(row);
      });

      this.syncInsertUi();
      this.highlightInsertTarget();

      if (scrollY != null) window.scrollTo(0, scrollY);

      if (options.scrollToIndex != null) {
        const target = list.querySelector('.step-row[data-idx="' + options.scrollToIndex + '"]');
        if (target) {
          target.classList.add('insert-marker');
          target.scrollIntoView({ block: 'nearest', behavior: 'smooth' });
        }
      }

      const count = this.el('step-count');
      if (count) count.textContent = '(' + this.recipe.steps.length + ')';
    },

    addStep() {
      this.syncAllStepsFromDom();
      this.readInsertFromDom();
      const at = this.resolveInsertIndex();
      this.recipe.steps.splice(at, 0, this.blankStep());
      this.renderSteps({ skipSync: true, scrollToIndex: at });
      let posLabel = 'at the beginning';
      if (this.insertMode === 'end' || at >= this.recipe.steps.length - 1) {
        posLabel = 'at the end';
      } else if (this.insertMode === 'before') {
        posLabel = 'before step ' + (at + 1);
      } else if (this.insertMode === 'after') {
        posLabel = 'after step ' + at;
      }
      this.setStatus('Added blank step ' + posLabel, 'ok');
      const row = this.el('steps-list')?.querySelector('.step-row[data-idx="' + at + '"]');
      row?.querySelector('[data-fn-select]')?.focus();
    },

    async loadCompiled() {
      const d = await this.api('compile', 'POST', { recipe: this.recipe });
      this.compiledSteps = d.compiled || [];
    },

    async loadRecipe() {
      this.recipe = (await this.api('recipe')).recipe;
      if (!this.recipe.steps?.length) {
        this.recipe = (await this.api('import_csv', 'POST', { use_file: true })).recipe;
      }
      await this.loadCompiled();
    },

    async loadCatalog() {
      this.catalog = await this.api('catalog');
      this.dynamicOptions = this.catalog.dynamic_options || {};
      this.buildCatalogMap();
    },

    async saveRecipe() {
      this.syncAllStepsFromDom();
      const d = await this.api('save', 'POST', { recipe: this.recipe });
      await this.loadCompiled();
      this.renderSteps();
      this.setStatus('Saved workflow (' + (d.rows || this.recipe.steps.length) + ' steps)', 'ok');
      return d;
    },

    async normalizeRecipe() {
      this.syncAllStepsFromDom();
      const data = await this.api('normalize_recipe', 'POST', { recipe: this.recipe });
      this.recipe = data.recipe;
      await this.loadCompiled();
      this.renderSteps();
      this.setStatus('Normalized ' + data.rows + ' steps', 'ok');
    },

    async importCsv() {
      if (!confirm('Replace workflow from CSV?')) return;
      this.recipe = (await this.api('import_csv', 'POST', { use_file: true })).recipe;
      await this.loadCompiled();
      this.renderSteps();
      this.setStatus('Imported from CSV', 'ok');
    },

    async loadRunOptions() {
      this.runOptions = await this.api('run_options');
      this.syncRunDefaults();
    },

    syncRunDefaults() {
      const idx = this.runOptions?.indices || {};
      const total = this.recipe.steps?.length || idx.total || 1;
      const startEl = this.el('run-start');
      const stopEl = this.el('run-stop');
      if (startEl && startEl.dataset.userSet !== '1') {
        startEl.min = '1';
        startEl.max = String(total);
        startEl.value = String(idx.operating_start || this.runOptions?.default_start || 1);
      }
      if (stopEl && stopEl.dataset.userSet !== '1') {
        stopEl.min = '1';
        stopEl.max = String(total);
        stopEl.value = String(
          idx.session_end || this.runOptions?.default_stop || idx.generate_step || total
        );
      }
      const sumSession = this.el('run-db-session');
      if (sumSession) {
        sumSession.textContent = this.runOptions?.current_session ?? '—';
      }
    },

    async runWorkflow(options) {
      options = options || {};
      const repeat = options.repeat
        ? Math.max(1, parseInt(this.el('run-repeat')?.value, 10) || 1)
        : 1;
      this.syncAllStepsFromDom();
      if (options.saveFirst) {
        await this.saveRecipe();
      }
      const start = parseInt(this.el('run-start')?.value, 10) || 0;
      const stop = parseInt(this.el('run-stop')?.value, 10) || 0;
      if (start > 0 && stop > 0 && stop < start) {
        throw new Error('Stop step must be at or after start step');
      }
      this.setStatus(
        repeat > 1 ? ('Running ' + repeat + ' cycles…') : 'Running workflow…',
        'info'
      );
      const d = await this.api('run_switchlists', 'POST', {
        recipe: this.recipe,
        format: this.el('run-format')?.value || 'phased',
        mode: repeat > 1 ? 'simulate' : 'current',
        start_step: start,
        stop_step: stop,
        session_count: repeat,
        run_prep: false,
        play_after: repeat > 1,
      });
      const lines = (d.summary || []).slice();
      if (d.start_step) lines.unshift('Steps ' + d.start_step + '–' + d.stop_step);
      if (d.warnings?.length) lines.push('', ...d.warnings);
      if (d.index_url) lines.push('', 'Sessions: ' + d.index_url);
      if (d.session_url) lines.push('Latest: ' + d.session_url);
      this.log(lines.join('\n'));
      this.setStatus(
        'Complete — session ' + (d.session || (d.sessions || []).join(', ') || ''),
        'ok'
      );
      this.runOptions = await this.api('run_options');
      this.syncRunDefaults();
      return d;
    },
  };

  global.WorkflowUI = WorkflowUI;
})(window);
