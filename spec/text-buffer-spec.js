const path = require('path')
const TextBuffer = require('../src/text-buffer')

describe('when a buffer is already open', () => {
  it('replaces foo( with bar( using /\bfoo\\(\b/gim', () => {
    const filePath = path.join(__dirname, 'fixtures', 'sample.js')
    const buffer = new TextBuffer()
    buffer.setPath(filePath)
    buffer.setText('foo(x)')
    buffer.replace(/\bfoo\(\b/gim, 'bar(')

    expect(buffer.getText()).toBe('bar(x)')
  })

  it('replaces tstat_fvars()->curr_setpoint[HEAT_EN] = new_tptr->heat_limit; with tstat_set_curr_setpoint(HEAT_EN, new_tptr->heat_limit);', () => {
    const filePath = path.join(__dirname, 'fixtures', 'sample.js')
    const buffer = new TextBuffer()
    buffer.setPath(filePath)
    buffer.setText('if (tstat_fvars()->curr_setpoint[HEAT_EN] > new_tptr->heat_limit) { tstat_fvars()->curr_setpoint[HEAT_EN] = new_tptr->heat_limit; }')
    buffer.replace(/tstat_fvars\(\)->curr_setpoint\[(.+?)\] = (.+?);/, 'tstat_set_curr_setpoint($1, $2);')

    expect(buffer.getText()).toBe('if (tstat_fvars()->curr_setpoint[HEAT_EN] > new_tptr->heat_limit) { tstat_set_curr_setpoint(HEAT_EN, new_tptr->heat_limit); }')
  })
})
