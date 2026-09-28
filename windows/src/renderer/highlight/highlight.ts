// The highlight page: label from the query (?label=…); ?render=1 draws a fake window behind it for the render check.
const q = new URLSearchParams(location.search);
const chip = document.getElementById('chip')!;
const label = q.get('label');
if (label) chip.textContent = label;
if (q.has('render')) {
  document.body.classList.add('render');
  (document.getElementById('app') as HTMLElement).hidden = false;
}
document.documentElement.lang = q.get('lang') ?? 'de';

export {};
