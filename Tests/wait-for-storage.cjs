const { expect } = require("playwright/test");

// IndexedDB is asynchronous. Poll the resolved value rather than the Promise.
module.exports = async function waitForStoredValue(page, read, arg) {
  let value;
  await expect.poll(async () => {
    value = await page.evaluate(read, arg);
    return Boolean(value);
  }, { timeout: 15000 }).toBe(true);
  return value;
};
