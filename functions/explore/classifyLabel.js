'use strict';

const {applyLabelClassification} = require('./parsePrice');
const {matchRawProcedureLabel} = require('./procedureMatch');

/**
 * Optional cheap label classifier. Numeric fields from the model are ignored.
 */
async function classifyLabelIfNeeded(rawLabel, requestedProcedure) {
  const det = matchRawProcedureLabel(rawLabel, requestedProcedure);
  if (det.rejectReason) return det;
  if (det.family && det.family !== 'other') return det;

  const key = String(process.env.OPENAI_API_KEY || '').trim();
  if (!key) return det;

  try {
    console.log('[CLASSIFY] AI label classifier used');
    const res = await fetch('https://api.openai.com/v1/chat/completions', {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${key}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        model: 'gpt-4o-mini',
        temperature: 0,
        response_format: {type: 'json_object'},
        messages: [
          {
            role: 'system',
            content: 'Classify an aesthetic procedure label. Return JSON only: ' +
              '{"family":"botox|filler|laser|peel|rhinoplasty|breast_augmentation|hair_transplant|other",' +
              '"canonical":"string","confidence":0.0}. Never return a price.',
          },
          {
            role: 'user',
            content: `Raw procedure label:\n"${rawLabel}"\nRequested:\n${requestedProcedure}`,
          },
        ],
      }),
    });
    if (!res.ok) return det;
    const json = await res.json();
    const content = json.choices && json.choices[0] && json.choices[0].message
      ? json.choices[0].message.content : '';
    const parsed = JSON.parse(content);
    const merged = applyLabelClassification(
        {procedureFamily: det.family, procedureCanonical: det.canonical, confidence: det.confidence,
          priceMin: 0, priceMax: 0, currency: '', rawPriceText: ''},
        parsed,
    );
    return {
      family: merged.procedureFamily || 'other',
      canonical: merged.procedureCanonical || '',
      confidence: merged.confidence || 0,
      rejectReason: '',
    };
  } catch (e) {
    console.log(`[CLASSIFY] failed: ${e.message || e}`);
    return det;
  }
}

module.exports = {classifyLabelIfNeeded};
