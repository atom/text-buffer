const path = require('path')
const TextBuffer = require('../src/text-buffer')

describe('when a buffer is already open', () => {
  const filePath = path.join(__dirname, 'fixtures', 'sample.js')
  const buffer = new TextBuffer()

  it('replaces foo( with bar( using /\bfoo\\(\b/gim', () => {
    buffer.setPath(filePath)
    buffer.setText('foo(x)')
    buffer.replace(/\bfoo\(\b/gim, 'bar(')

    expect(buffer.getText()).toBe('bar(x)')
  })

  describe('should properly replace regex literals', () => {
    it('replaces tstat_fvars()->curr_setpoint[HEAT_EN] = new_tptr->heat_limit; with tstat_set_curr_setpoint(HEAT_EN, new_tptr->heat_limit);', () => {
      buffer.setPath(filePath)
      buffer.setText('tstat_fvars()->curr_setpoint[HEAT_EN] = new_tptr->heat_limit;')
      buffer.replace(/tstat_fvars\(\)->curr_setpoint\[(.+?)\] = (.+?);/, 'tstat_set_curr_setpoint($1, $2);')

      expect(buffer.getText()).toBe('tstat_set_curr_setpoint(HEAT_EN, new_tptr->heat_limit);')
    })

    it('replaces atom/flight-manual.atom.io with atom/flight-manualatomio', () => {
      buffer.setText('atom/flight-manual.atom.io')
      buffer.replace(/\.(atom)\./, '$1')

      expect(buffer.getText()).toBe('atom/flight-manualatomio')
    })
  })
})
