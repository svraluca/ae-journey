'use strict';

/**
 * MarketplaceProvider — Fresha first; Booksy (etc.) later.
 *
 * Implementations must never invent prices and must keep literal service text.
 */
class MarketplaceProvider {
  get id() {
    throw new Error('MarketplaceProvider.id not implemented');
  }

  /**
   * @param {{city: string, countryCode?: string, maxResults?: number}} _opts
   * @return {Promise<object[]>} raw venue records
   */
  async discoverCity(_opts) {
    throw new Error('MarketplaceProvider.discoverCity not implemented');
  }

  /**
   * @param {object} _raw
   * @return {object|null} normalized venue
   */
  normalizeVenue(_raw) {
    throw new Error('MarketplaceProvider.normalizeVenue not implemented');
  }

  /**
   * @param {object} _rawVenue
   * @return {object[]} normalized service / variant rows with literal prices only
   */
  normalizeServices(_rawVenue) {
    throw new Error('MarketplaceProvider.normalizeServices not implemented');
  }
}

module.exports = {MarketplaceProvider};
