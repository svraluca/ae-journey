"""Run the real Python engine, optionally rechecking URL leads from an audit.
Never imports old prices or replaces search/fetch functions. No Firestore writes.
"""
import argparse
import asyncio
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import sys
import time
import traceback

PROCEDURES = ['botox', 'filler', 'breast_augmentation', 'chemical_peel', 'rhinoplasty', 'hair_transplant']

async def main(args):
    root = Path(args.repo).resolve()
    if args.env_file:
        from dotenv import load_dotenv
        load_dotenv(args.env_file, override=True)
    os.environ.update(PYTHON_DOTENV_DISABLED='1', ENABLE_FIRESTORE='false',
                      ENABLE_BACKGROUND_REFRESH='false', PYTHONDONTWRITEBYTECODE='1')
    sys.path.insert(0, str(root / 'python'))
    import aesthetic_price_discovery_v11_67 as e
    leads = json.loads(Path(args.source_audit).read_text()) if args.source_audit else {}
    report = dict(started_at=datetime.now(timezone.utc).isoformat(),city=args.city,
                  country_code=args.country,backend_version=e.app.version,
                  extraction_revision=e.PRICE_EXTRACT_REVISION,
                  run_type='known_url_live_recheck' if leads else 'unseeded_city_discovery',
                  no_mocked_search_or_fetch=True, no_external_database_reads_or_writes=True,
                  search_key_present=bool(os.getenv('SERPER_API_KEY')),
                  exa_key_present=bool(os.getenv('EXA_API_KEY')),
                  places_key_present=bool(os.getenv('GOOGLE_PLACES_API_KEY')),
                  limitations=['Local Python engine; not a physical-phone or production Firebase test.',
                    'Known URL rechecks are separate from unseeded city discovery.'], procedures={})
    output = Path(args.output)
    output.parent.mkdir(parents=True,exist_ok=True)
    for proc in args.procedures:
        known = leads.get('procedures',{}).get(proc,{})
        urls = list(known.get('sources', {})) if isinstance(known, dict) else []
        for row in known.get('rows', known.get('offers', [])) if isinstance(known, dict) else []:
            if isinstance(row, dict) and row.get('source_url'):
                urls.append(row['source_url'])
        urls = list(dict.fromkeys(urls))
        queue = asyncio.Queue()
        token = e._hybrid_progress.set(queue)
        request = e.HybridDiscoverRequest(city=args.city, procedure=proc, country_code=args.country,
            display_limit=4, collection_target=12, stored_count=2, fresh_count=2,
            enable_growth_search=True,max_growth_rounds=3,fast_interactive_search=False,
            force_full_growth_search=True,economical_growth=True,stream_progress=True,
            debug=True,serper_first=True,saved_source_urls=urls)
        started = time.monotonic()
        task = asyncio.create_task(e._discover_hybrid_impl(request))
        events, first, exception = [], None, None
        result = None
        try:
            while not task.done():
                try:
                    event = await asyncio.wait_for(queue.get(),timeout=0.25)
                    elapsed = round((time.monotonic()-started)*1000)
                    if event.get('event')=='partial':
                        rows = event.get('candidate_results') or event.get('display_results') or []
                        if rows and first is None:
                            first=elapsed
                            print(json.dumps({'procedure':proc,'first_card_ms':first,'partial_count':len(rows)},ensure_ascii=False),flush=True)
                        events.append({'at_ms':elapsed,'event':'partial','count':len(rows)})
                    elif event.get('event')=='progress':
                        events.append({'at_ms':elapsed,**event.get('progress',{})})
                except asyncio.TimeoutError:
                    pass
                if time.monotonic()-started>args.timeout:
                    task.cancel()
                    exception='audit_deadline_exceeded'
                    break
            if not task.cancelled() and exception is None:
                result=await task
        except Exception as exc:
            traceback.print_exc()
            exception=type(exc).__name__+': '+str(exc)[:400]
        finally:
            if not task.done(): task.cancel()
            await asyncio.gather(task,return_exceptions=True)
            e._hybrid_progress.reset(token)
        data=result.model_dump(mode='json') if result is not None else {}
        rows=data.get('candidate_results') or data.get('display_results') or []
        usable=[r for r in rows if e._app_can_show_row(e.DisplayClinicPrice.model_validate(r))]
        report['procedures'][proc]=dict(elapsed_ms=round((time.monotonic()-started)*1000),
            first_card_ms=first, verified_count=len(usable), source_url_lead_count=len(urls),
            display_count=len(data.get('display_results',[])),exception=exception,
            search_errors=data.get('search_errors',[]),
            growth_search_errors=data.get('growth_search_errors',{}),
            verified_offers=usable, events=events, response=data)
        output.write_text(json.dumps(report,ensure_ascii=False,indent=2))
        print(json.dumps({'procedure':proc,'count':len(usable),'elapsed_ms':report['procedures'][proc]['elapsed_ms'],
            'first_card_ms':first,'errors':report['procedures'][proc]['search_errors'],
            'growth_errors':report['procedures'][proc]['growth_search_errors'],
            'exception':exception},ensure_ascii=False),flush=True)
    report['finished_at']=datetime.now(timezone.utc).isoformat()
    output.write_text(json.dumps(report,ensure_ascii=False,indent=2))

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--repo',default=str(Path(__file__).resolve().parents[1]))
    p.add_argument('--city',required=True)
    p.add_argument('--country',required=True)
    p.add_argument('--procedures',nargs='+',choices=PROCEDURES,default=PROCEDURES)
    p.add_argument('--output',required=True)
    p.add_argument('--source-audit',help='Optional source URLs only; never old fees. Distinct from cold discovery.')
    p.add_argument('--env-file',help='Optional local credentials file; values are never printed.')
    p.add_argument('--timeout',type=float,default=180)
    asyncio.run(main(p.parse_args()))
