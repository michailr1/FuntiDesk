// User-selected files/handles live only in this panel's memory. No writes or recursive scan.
export class LocalFiles {
  constructor(change) { this.change = change; this.generation = 0; this.entries = []; this.stack = []; }
  clear() { this.generation++; this.entries = []; this.stack = []; this.selected = null; this.busy = false; this.error = ''; }
  pick(files) {
    const items = Array.from(files); if(items.length > 10000)throw Error('local_limit');
    this.clear(); this.entries = items.map(file => ({name:file.name,size:file.size,entry_type:4,file}));
    this.selected = this.entries.length === 1 ? this.entries[0].file : null; this.change();
  }
  async folder() {
    const generation = ++this.generation; this.busy = true; this.error = ''; this.change();
    try {
      const handle = await window.showDirectoryPicker({mode:'read'});
      if(generation === this.generation)await this.load([handle]);
    } catch(error) {
      if(generation === this.generation) {this.busy = false; if(error.name !== 'AbortError')this.error = 'local_access'; this.change();}
    }
  }
  async load(stack) {
    const generation = ++this.generation; this.busy = true; this.error = ''; this.change();
    try {
      const handles = [];
      for await(const handle of stack.at(-1).values()) {
        if(generation !== this.generation)return;
        handles.push(handle); if(handles.length > 10000)throw Error('local_limit');
      }
      const entries = [];
      for(let i=0;i<handles.length;i+=32) {
        const batch = await Promise.all(handles.slice(i,i+32).map(async handle => {
          if(handle.kind === 'directory')return {name:handle.name,entry_type:0,handle};
          const file = await handle.getFile(); return {name:file.name,entry_type:4,size:file.size,file};
        }));
        if(generation !== this.generation)return; entries.push(...batch);
      }
      this.stack = stack; this.entries = entries; this.selected = null;
    } catch(error) {if(generation !== this.generation)return; this.error = error.message === 'local_limit' ? 'local_limit' : 'local_access';}
    if(generation === this.generation) {this.busy = false; this.change();}
  }
  choose(entry) {
    if(this.busy || !this.entries.includes(entry))return;
    if(entry.handle)return this.load([...this.stack,entry.handle]);
    this.selected = entry.file; this.change();
  }
  up() { if(!this.busy && this.stack.length > 1)return this.load(this.stack.slice(0,-1)); }
}
