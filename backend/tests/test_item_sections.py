"""The shop's sections (ADR-093 amendment; the owner, 21 Nov 2026).

- A section is the kind with no karat, over its categories: set by the owner,
  a name once (its case and spaces not a second name).
- A category is in one section or none; renaming it does not move it.
- A scrap category takes none: scrap is not shown.
- A section with categories is not deleted -- stopped instead.
- The first suggestion is the category's name with no karat and nothing in
  brackets; saved only as the owner sends it, each named section made once.
- The derived group is gone from a category's words: one grouping, its section.

Run:
    python -m pytest tests/test_item_sections.py -v
"""
import uuid

import pytest

from models import Category, ItemSection, db
from services.item_sections import (SectionRefused, assign, create_section, delete_section, set_category_section,
                                    suggested_name)
from tests.test_stock_count import NOW


@pytest.fixture(autouse=True)
def _fenced(db_fence):
    yield


def _category(name, karat, scrap=False):
    c = Category(name=f'{name} {karat}', karat=str(karat), is_scrap=scrap)
    db.session.add(c)
    db.session.flush()
    return c


def _tag():
    return uuid.uuid4().hex[:5]


def test_a_section_is_a_name_once():
    name = f'أساور {_tag()}'
    create_section(name, by='t', now=NOW)
    for again in (name, f'  {name}  ', name.replace('أساور', 'أساور ')):
        with pytest.raises(SectionRefused) as refused:
            create_section(again, by='t', now=NOW)
        assert refused.value.code == 'section_exists', again
    with pytest.raises(SectionRefused) as empty:
        create_section('   ', by='t', now=NOW)
    assert empty.value.code == 'section_name_required'


def test_a_category_in_one_section_kept_when_it_is_renamed(app, auth_headers):
    from tests.test_wage_treatment_follows_the_setting import flask_app
    from flask import g
    t = _tag()
    eighteen, twentyone = _category(f'سوار ذهب {t}', 18), _category(f'سوار ذهب {t}', 21)
    section = create_section(f'أساور {t}', by='t', now=NOW)
    set_category_section(eighteen, section.id)
    set_category_section(twentyone, section.id)
    from services.item_sections import sections
    assert {c['id'] for c in next(s for s in sections() if s['id'] == section.id)['categories']} == \
        {eighteen.id, twentyone.id}
    db.session.commit()
    g.pop('current_user', None)
    r = flask_app.test_client().put(f'/api/categories/{eighteen.id}', headers=auth_headers,
                                    json={'name': f'سوار ناعم {t} 18'})
    assert r.status_code == 200, r.get_data(as_text=True)
    body = r.get_json()
    assert (body['section_id'], body['section_name']) == (section.id, section.name), 'renamed, not moved'
    assert 'group_name' not in body, 'one grouping: the derived group is gone'
    other = create_section(f'أساور ناعمة {t}', by='t', now=NOW)
    scrap = _category(f'كسر سوار {t}', 21, scrap=True)
    db.session.commit()
    g.pop('current_user', None)
    moved = flask_app.test_client().put(f'/api/categories/{eighteen.id}', headers=auth_headers,
                                        json={'section_id': other.id})
    assert moved.get_json()['section_id'] == other.id, 'its section set where the category is edited'
    g.pop('current_user', None)
    refused = flask_app.test_client().put(f'/api/categories/{scrap.id}', headers=auth_headers,
                                          json={'section_id': other.id})
    assert (refused.status_code, refused.get_json()['error']) == (400, 'section_scrap')


def test_scrap_takes_no_section_and_a_section_in_use_is_not_deleted():
    t = _tag()
    scrap = _category(f'كسر {t}', 21, scrap=True)
    section = create_section(f'خواتم {t}', by='t', now=NOW)
    with pytest.raises(SectionRefused) as refused:
        set_category_section(scrap, section.id)
    assert refused.value.code == 'section_scrap'
    ring = _category(f'خاتم ذهب {t}', 21)
    set_category_section(ring, section.id)
    with pytest.raises(SectionRefused) as used:
        delete_section(section)
    assert used.value.code == 'section_in_use'
    set_category_section(ring, None)
    delete_section(section)
    assert db.session.get(ItemSection, section.id) is None


def test_the_suggestion_is_the_name_with_no_karat_nor_brackets():
    t = _tag()
    assert suggested_name(_category(f'سوار ذهب (دائري) {t}', 21)) == f'سوار ذهب {t}'
    assert suggested_name(_category(f'عقد ذهب (ناعم) {t}', 18)) == f'عقد ذهب {t}'
    assert suggested_name(_category(f'كسر عيار {t}', 21, scrap=True)) is None


def test_saved_as_the_owner_sends_it_each_section_made_once():
    t = _tag()
    a, b, c = _category(f'سوار ذهب {t}', 18), _category(f'سوار ذهب {t}', 21), _category(f'سوار دائري {t}', 21)
    before = ItemSection.query.count()
    assign([{'category_id': a.id, 'section_name': f'أساور {t}'},
            {'category_id': b.id, 'section_name': f'  أساور {t} '},
            {'category_id': c.id, 'section_name': f'أساور {t}'}], by='t', now=NOW)
    assert ItemSection.query.count() == before + 1, 'one section, made once'
    assert len({a.section_id, b.section_id, c.section_id}) == 1
    assign([{'category_id': c.id, 'section_name': ''}], by='t', now=NOW)
    assert c.section_id is None, 'an empty name takes its section away'


def test_the_routes_carry_it(app, auth_headers):
    from flask import g
    from tests.test_wage_treatment_follows_the_setting import flask_app
    t = _tag()
    a = _category(f'دبلة ذهب {t}', 21)
    db.session.commit()
    client = flask_app.test_client()
    g.pop('current_user', None)
    rows = client.get('/api/item-sections/suggestions', headers=auth_headers).get_json()['categories']
    assert next(r for r in rows if r['category_id'] == a.id)['suggested'] == f'دبلة ذهب {t}'
    g.pop('current_user', None)
    r = client.post('/api/item-sections/assign', headers=auth_headers,
                    json={'assignments': [{'category_id': a.id, 'section_name': f'دبل {t}'}]})
    assert r.status_code == 200, r.get_data(as_text=True)
    g.pop('current_user', None)
    sections = client.get('/api/item-sections', headers=auth_headers).get_json()['sections']
    mine = next(s for s in sections if s['name'] == f'دبل {t}')
    assert [c['id'] for c in mine['categories']] == [a.id]
    g.pop('current_user', None)
    assert client.delete(f'/api/item-sections/{mine["id"]}', headers=auth_headers).status_code == 409
    g.pop('current_user', None)
    for method, url in (('get', '/api/item-sections'), ('post', '/api/item-sections/assign')):
        assert getattr(client, method)(url).status_code == 401, url
