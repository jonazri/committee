// Hermetic checks of workflow dispatch and its emitted Gemini retry commands.
// Run with: node scripts/reviewer-model-smoke.cjs (no provider calls).
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const root = path.resolve(__dirname, '..');
const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;
const source = fs.readFileSync(path.join(root, 'prompts/committee-review.js'), 'utf8');
const workflow = new AsyncFunction('args', 'phase', 'log', 'agent', 'pipeline',
  source.replace(/^export const /m, 'const '));
const scratch = fs.mkdtempSync(path.join(root, '.tmp.models-'));
const projectRoot = path.join(scratch, 'reviewed repo');
const sessionDir = path.join(projectRoot, '.committee/session-test');
const promptsDir = path.join(scratch, 'prompts');
const tempDir = path.join(scratch, 'tmp');
const callLog = path.join(scratch, 'model-calls');

async function dispatch(overrides = {}) {
  const calls = {};
  const result = await workflow({
    projectRoot, sessionDir, promptsDir, scopeType: 'files',
    diffPath: path.join(sessionDir, 'diff.txt'), diffStatPath: 'stat.txt', ...overrides,
  }, () => {}, () => {}, async (prompt, options) => {
    calls[options.label] = { prompt, ...options };
    return { ran_ok: true, findings: [] };
  }, async (items, ...stages) => Promise.all(items.map(async item => {
    for (const stage of stages) item = await stage(item);
    return item;
  })));
  assert(result.quorum >= 2);
  return calls;
}

function shell(command, outcome) {
  const result = spawnSync('bash', ['-c', command], {
    encoding: 'utf8', cwd: projectRoot,
    env: { ...process.env, TMPDIR: tempDir, MODEL_CALL_LOG: callLog, NEON_RESULT: outcome },
  });
  assert.equal(result.status, 0, result.stderr || String(result.error));
}

async function retryCase(outcome, override, expectedModels) {
  fs.writeFileSync(callLog, '');
  const calls = await dispatch(override ? { geminiProModel: override } : {});
  const lines = calls['review:Gemini-Pro'].prompt.split('\n').map(line => line.trim());
  shell(lines.find(line => line.startsWith('cd ')), outcome);
  const retry = lines.find(line => line.startsWith('[ -s '));
  if (override) assert.equal(retry, undefined, 'explicit pin must suppress retry');
  else {
    assert(retry, 'default pin must supply a retry');
    // Simulate the launcher's classification of a clearly non-review response.
    if (outcome === 'non-review') shell(lines.find(line => line.startsWith('mv -f ')), outcome);
    shell(retry, outcome);
  }
  assert.deepEqual(fs.readFileSync(callLog, 'utf8').trim().split('\n'), expectedModels);
  if (!override) assert.match(fs.readFileSync(path.join(sessionDir, 'gemini-pro.md'), 'utf8'), /review findings/);
  assert.deepEqual(fs.readdirSync(tempDir), [], 'per-call homes must be cleaned');
}

(async () => {
  for (const dir of [sessionDir, promptsDir, tempDir]) fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(sessionDir, 'diff.txt'), '+reviewed data\n');
  fs.writeFileSync(path.join(promptsDir, 'agy-review.sh'), `#!/usr/bin/env bash
set -eu
cat >/dev/null
printf '%s\\n' "$2" >> "$MODEL_CALL_LOG"
: > "$5"; : > "$6"
if [ "$2" = gemini-4-hydrogen-high ] || [ "$NEON_RESULT" = review ]; then
  printf 'review findings\\n' > "$5"
elif [ "$NEON_RESULT" = non-review ]; then
  printf 'No artifact received\\n' > "$5"
fi
`);

  for (const model of ['opus', 'sonnet', 'haiku', 'fable', 'claude-opus-5-5', 'claude-sonnet-5-5']) {
    const calls = await dispatch({ reviewerModel: model, kiroModel: 'claude-sonnet-5.5' });
    assert.equal(calls['review:Claude'].model, model, `preserve pin ${model}`);
    assert.match(calls['review:Kiro'].prompt, /--model claude-sonnet-5\.5 --no-interactive/);
  }
  for (const model of [undefined, '', 'bad model', '$(touch PWN)']) {
    const calls = await dispatch({ reviewerModel: model });
    assert.equal(calls['review:Claude'].model, 'opus');
  }
  for (const scopeType of ['files', 'plan', 'commit', 'branch_diff', 'uncommitted', 'sha_range', 'pr']) {
    for (const trust of ['auto', 'read-only']) {
      const calls = await dispatch({ scopeType, trust });
      assert.match(calls['review:Codex'].prompt, /-c model=gpt-6\.2-astra/);
      assert.match(calls['review:Kiro'].prompt, /--model claude-opus-5\.5/);
      assert.match(calls['review:Gemini'].prompt, /'gemini-4-neon-high'/);
    }
  }
  const neon = 'Gemini 4 Neon (High)', hydrogen = 'gemini-4-hydrogen-high';
  await retryCase('empty', null, [neon, hydrogen]);
  await retryCase('review', null, [neon]);
  await retryCase('non-review', null, [neon, hydrogen]);
  await retryCase('empty', 'gemini-4-neon-high', ['gemini-4-neon-high']);
  console.log('PASS: model pins, defaults, scope/trust dispatch, and executable Gemini retry routing');
})().catch(error => { console.error(error); process.exitCode = 1; })
  .finally(() => fs.rmSync(scratch, { recursive: true, force: true }));
