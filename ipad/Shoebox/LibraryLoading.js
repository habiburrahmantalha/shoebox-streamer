// The web player replaces #app when the library loads or a connection error occurs.
const libraryRoot = document.querySelector('#app');
if (libraryRoot && !libraryRoot.hasChildNodes()) {
  libraryRoot.innerHTML = `<div class="empty" role="status" aria-live="polite">
    <span class="spinner" aria-hidden="true" style="display:inline-block;width:28px;height:28px"></span>
    <h2>Loading your library…</h2>
    <p>This can take a moment for a large folder. Keep your Mac awake.</p>
  </div>`;
}
