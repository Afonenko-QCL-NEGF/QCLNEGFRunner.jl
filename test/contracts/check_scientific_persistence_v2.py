"""Independent literal Python/HDF5 fixture oracle. Never invokes Julia or numerical work."""
from __future__ import annotations
import hashlib
import json
from copy import deepcopy
from pathlib import Path
from importlib.resources import files
import sys

import h5py
import numpy as np
from qcl_negf_contracts import schema_validator
from qcl_negf_contracts.messages import decode
from qcl_negf_contracts.results import (
    validate_manifest, validate_pointer, validate_catalog_page,
    validate_checkpoint_declaration, validate_scientific_record,
)

def text(value):
    return value.decode('utf-8') if isinstance(value, bytes) else str(value)


def pairs(value):
    def key(first):
        return first['value'] if isinstance(first, dict) else first
    return {key(item['fields']['first']): item['fields']['second'] for item in value}


class FixtureReader:
    def __init__(self, root: Path):
        self.root = root.resolve(strict=True)
        self.verified: dict[tuple[str, str], bytes] = {}
        self.records = []

    def path(self, name):
        assert isinstance(name, str) and name and not name.startswith('/')
        parts = name.split('/')
        assert all(part not in ('', '.', '..') for part in parts)
        path = self.root
        for part in parts:
            path /= part
            assert not path.is_symlink()
        return path

    def file(self, ref):
        key = (ref['path'], ref['sha256'])
        if key not in self.verified:
            path = self.path(ref['path'])
            digest = hashlib.sha256()
            size = 0
            with path.open('rb') as stream:
                while block := stream.read(1024 * 1024):
                    digest.update(block)
                    size += len(block)
            assert str(size) == ref['bytes'] and digest.hexdigest() == ref['sha256']
            self.verified[key] = b''
        return self.path(ref['path'])

    def document(self, ref):
        return decode(self.file(ref).read_bytes(), maximum=8 * 1024 * 1024)

    @staticmethod
    def ordered_record(page):
        assert len(page['artifacts']) in (1, 2)
        if len(page['artifacts']) == 2:
            assert page['artifacts'][0]['path'] in page['artifacts'][1]['dependencies']
        return page['artifacts'][-1]

    def manifest(self, directory, recovery=False):
        pointer_path = directory / ('recovery/current.json' if recovery else 'current.json')
        pointer = validate_pointer(decode(pointer_path.read_bytes(), maximum=1024 * 1024))
        doc = validate_manifest(self.document(pointer['manifest']))
        assert doc['identity'] == pointer['identity'] and doc['generation'] == pointer['generation']
        return doc, pointer['manifest']

    def array(self, wire):
        path = self.file(wire['file'])
        with h5py.File(path, 'r') as file:
            assert text(file['metadata'].attrs['schema_version']) == '5.0'
            dataset = file[wire['dataset']]
            assert isinstance(dataset, h5py.Dataset)
            if dataset.size:
                assert dataset.chunks is not None
                assert np.prod(dataset.chunks) * dataset.dtype.itemsize <= 256 * 1024
            shape = tuple(int(n) for n in wire['shape'])
            assert dataset.shape == shape
            # Julia compensates its HDF5 dimension reversal before writing. Python sees logical axes.
            out = dataset[...]
            expected = {
                'Float64': np.dtype('<f8'), 'Float32': np.dtype('<f4'),
                'ComplexF64': np.dtype('<c16'), 'ComplexF32': np.dtype('<c8'),
                'Int64': np.dtype('<i8'), 'UInt64': np.dtype('<u8'),
                'Int32': np.dtype('<i4'), 'UInt32': np.dtype('<u4'),
                'Int16': np.dtype('<i2'), 'UInt16': np.dtype('<u2'),
                'Int8': np.dtype('i1'), 'UInt8': np.dtype('u1'), 'Bool': np.dtype('bool'),
            }[wire['eltype']]
            assert out.dtype == expected and wire['order'] == 'F'
            return out

    def history(self, manifest):
        pin = manifest['history']
        chain = []
        head = pin['head']
        while head is not None:
            page = self.document(head)
            chain.append((head, page))
            head = page['previous']['head'] if page['previous'] else None
        paths = set()
        previous = previous_page = previous_ref = None
        records = []
        for ref, page in reversed(chain):
            validate_catalog_page(page, previous=previous, previous_page=previous_page, previous_ref=previous_ref)
            artifact = self.ordered_record(page)
            for artifact in page['artifacts']:
                assert artifact['path'] not in paths
                paths.add(artifact['path'])
            # Authenticated page order identifies the record leaf. Arrays remain lazy.
            with h5py.File(self.file(artifact), 'r') as file:
                assert text(file['metadata'].attrs['schema']) == 'qcl-negf-scientific-history-v5'
                assert text(file['metadata'].attrs['representation']) == 'record_leaf'
                offsets = file['records/offsets'][...]
                ordinals = file['records/stream_ordinal'][...]
                assert offsets.dtype == np.dtype('<u8') and len(offsets) == len(ordinals) + 1
                assert offsets[0] == 0 and offsets[-1] == len(file['records/json_utf8'])
                assert np.all(offsets[1:] > offsets[:-1])
                for i in range(len(ordinals)):
                    raw = bytes(file['records/json_utf8'][int(offsets[i]):int(offsets[i + 1])])
                    row = decode(raw, maximum=1024 * 1024)
                    context = {}
                    if row['target'] and row['target']['scope'] == 'parent_checkpoint':
                        parent = manifest['lineage']['parent_state']
                        pm = validate_manifest(self.document(parent['manifest']))
                        context = dict(parent_checkpoint=self.document(pm['checkpoint']),
                                       parent_state=parent, parent_manifest_ref=parent['manifest'])
                    validate_scientific_record(row, **context)
                    assert int(row['stream_ordinal']) == int(ordinals[i])
                    array_files = []
                    def refs(value):
                        if isinstance(value, dict):
                            if value.get('kind') == 'array' and 'file' in value:
                                array_files.append(value['file'])
                            for child in value.values():
                                refs(child)
                        elif isinstance(value, list):
                            for child in value:
                                refs(child)
                    refs(row['core'])
                    assert not array_files or len(page['artifacts']) == 2
                    if array_files:
                        owner = {key: page['artifacts'][0][key] for key in array_files[0]}
                        assert all(ref == owner for ref in array_files)
                    records.append(row)
            previous = dict(head=ref, entries=page['entries'], **page['totals'])
            previous_page, previous_ref = page, ref
        assert len(paths) == int(pin['entries'])
        assert len(records) == int(pin['records'])
        assert [int(row['stream_ordinal']) for row in records] == list(range(1, len(records) + 1))
        return records


def main(root):
    reader = FixtureReader(root)
    closure = decode((root / 'graph-closure.json').read_bytes(), maximum=8 * 1024 * 1024)
    layout = json.loads(files('qcl_negf_contracts').joinpath('core_layout.json').read_text())
    assert closure['core_layout_sha256'] == layout['layout_sha256']
    assert set(closure['samples']) == set(layout['graph']['nodes']) and len(closure['samples']) == 129
    validator = schema_validator('core-state.schema.json')
    for name, sample in closure['samples'].items():
        # Public bundled schema, ordinary jsonschema selection; no Runner codec helpers.
        validator.evolve(schema={**validator.schema, 'anyOf': [{'$ref': '#/$defs/' + name}]}).validate(sample)
    shapes = decode((root / 'codec-shapes.json').read_bytes(), maximum=1024 * 1024)['arrays']
    actual = [reader.array(wire) for wire in shapes]
    bits = np.array([0, 0x8000000000000000, 0x7ff0000000000000, 0xfff0000000000000,
                     0x7ff8000000000001, 0x7ff8000000000002], dtype='<u8')
    np.testing.assert_array_equal(actual[0].view('<u8'), bits)
    np.testing.assert_array_equal(actual[1].real.copy().view('<u8'), bits.reshape((2, 3), order='F'))
    np.testing.assert_array_equal(actual[1].imag.copy().view('<u8'), bits[::-1].reshape((2, 3), order='F'))
    expected = np.arange(1, 13).reshape((3, 2, 1, 2), order='F')
    np.testing.assert_array_equal(actual[2], expected - 1j * expected)
    assert actual[3].shape == (0,) and actual[4].shape == (0, 3) and actual[5].shape == (0, 2, 1, 1)
    np.testing.assert_array_equal(actual[6], [False, True, False])
    np.testing.assert_array_equal(actual[7], [-2**63, 2**63 - 1])
    large = np.arange(1, 257**2 + 1).reshape((257, 257), order='F')
    np.testing.assert_array_equal(actual[8], large - 1j * large)
    history, _ = reader.manifest(root / 'history')
    page = reader.document(history['history']['head'])
    assert len(page['artifacts']) == 2
    for mutate in ('swap', 'count', 'dependency'):
        bad = deepcopy(page)
        if mutate == 'swap':
            bad['artifacts'].reverse()
        elif mutate == 'count':
            bad['artifacts'].append(deepcopy(bad['artifacts'][0]))
        else:
            bad['artifacts'][-1]['dependencies'] = []
        try:
            reader.ordered_record(bad)
        except AssertionError:
            pass
        else:
            raise AssertionError('ordered catalog failed to reject ' + mutate)
    rows = reader.history(history)
    assert len(rows) == 2 and [row['core']['fields']['sequence']['decimal'] for row in rows] == ['7', '11']
    for index, row in enumerate(rows):
        fields = row['core']['fields']
        assert len(fields) == 16 and fields['action'] == {'kind': 'symbol', 'value': 'append'}
        assert fields['stage']['value'] == ('scba' if index == 0 else 'outer')
        assert fields['discretization_id'] == 'grid-0' and fields['basis_id'] == 'basis-0'
        assert fields['domain_revision']['decimal'] == '0' and fields['outer_iteration']['decimal'] == '1'
        assert fields['converged'] is False and fields['status']['value'] == 'running'
        assert fields['quality']['value'] == 'unresolved'
        assert fields['strict_streak']['decimal'] == fields['diagnostic_streak']['decimal'] == '0'
        assert fields['inner_iteration'] == ({'kind': 'integer', 'type': 'Int64', 'decimal': '1'} if index == 0 else None)
    scalars = ('r_D', 'r_A', 'r_K', 'r_Σ', 'r_λ', 'λ', 'r_PSD', 'r_caus', 'r_roundoff',
               'r_Jchange', 'r_population', 'J', 'raw_charge', 'target_charge', 'normalized_charge', 'lambda_change')
    first = rows[0]['core']['fields']
    assert first['row']['fields']['ν']['decimal'] == '1'
    assert all(first['row']['fields'][name] == {'kind': 'ieee', 'type': 'f64', 'bits': '0000000000000000'} for name in scalars)
    expected_units = {name: '1' for name in ('ν', *scalars)}
    expected_units.update(J='A/m^2', raw_charge='L0^2 n_sheet', target_charge='L0^2 n_sheet', normalized_charge='L0^2 n_sheet')
    assert pairs(first['units']) == expected_units
    assert {name: reason['value'] for name, reason in pairs(first['missing_reasons']).items()} == {
        'witness': 'not_measured', 'physical_markers': 'not_sampled'}
    outer = rows[1]['core']['fields']['row']['fields']
    np.testing.assert_array_equal(reader.array(outer['populations']), [0.25, 0.75])
    np.testing.assert_array_equal(reader.array(outer['density']), [1., 2., 3.])
    assert pairs(rows[1]['core']['fields']['units'])['populations'] == 'target_sheet_fraction'
    assert pairs(rows[1]['core']['fields']['units'])['density'] == 'L0^3 n'
    assert rows[1]['core']['fields']['missing_reasons'] == []
    updates, _ = reader.manifest(root / 'updates')
    update_rows = reader.history(updates)
    assert [row['target']['scope'] if row['target'] else None for row in update_rows] == [
        None, 'same_leaf', 'sealed_leaf', None]
    for row in update_rows[1:3]:
        assert row['target']['append_ordinal'] == '1' and row['target']['row_offset'] == '0'
    assert update_rows[-1]['row_key']['domain_revision']['decimal'] == '1'
    live, _ = reader.manifest(root / 'exact')
    frozen, _ = reader.manifest(root / 'exact', recovery=True)
    assert live['checkpoint'] is None and live['history']['records'] == '2'
    assert frozen['checkpoint'] is not None and frozen['history']['records'] == '1'
    decl = validate_checkpoint_declaration(reader.document(frozen['checkpoint']), manifest=frozen)
    state = decl['state']['fields']
    assert len(state) == 17
    np.testing.assert_array_equal(reader.array(state['published_n']), np.ones(25))
    np.testing.assert_array_equal(reader.array(state['published_U']), np.zeros(25))
    outer_state = state['outer_history']['values'][0]['fields']
    np.testing.assert_array_equal(reader.array(outer_state['populations']), [0.25])
    np.testing.assert_array_equal(reader.array(outer_state['density']), np.full(25, 1.5))
    green = state['scba']['fields']['green']['fields']
    np.testing.assert_array_equal(reader.array(green['Gˡ']), np.zeros((9, 2, 1, 1), dtype=complex))
    np.testing.assert_array_equal(reader.array(green['Gᴿ']), np.full((9, 2, 1, 1), 1 - 1j))
    exact_row = state['scba']['fields']['history']['values'][0]['fields']
    expected_scalars = (.2, .3, .4, .5, 0., 1., 0., 0., 0., float('inf'), float('inf'), 3., 1., 1., 1., float('nan'))
    for name, value in zip(scalars, expected_scalars):
        expected_bits = format(np.float64(value).view(np.uint64).item(), '016x')
        assert exact_row[name] == {'kind': 'ieee', 'type': 'f64', 'bits': expected_bits}
    witness = exact_row['witness']['fields']
    np.testing.assert_array_equal(reader.array(witness['matrices']['entries'][0]['value']), [[1 + 2j]])
    np.testing.assert_array_equal(reader.array(witness['eigenvector']), [1 + 0j])
    warnings = pairs(state['warnings'][0]['fields']['entries'])
    assert warnings['signed_zero']['fields']['value']['bits'] == '8000000000000000'
    assert warnings['nan']['fields']['value']['bits'] == '7ff8000000000002'
    assert len(decl['witness_targets']) == 1
    assert len(reader.history(frozen)) == 1
    child, _ = reader.manifest(root / 'child', recovery=True)
    child_decl = validate_checkpoint_declaration(reader.document(child['checkpoint']), manifest=child)
    assert child_decl['history']['records'] == '1' and child_decl['history']['scba_rows'] == '0'
    assert child_decl['witness_targets'] == decl['witness_targets']
    child_rows = reader.history(child)
    assert child_rows[0]['target']['scope'] == 'parent_checkpoint'
    assert child_rows[0]['target']['anchor_state'] == child['lineage']['parent_state']
    bridge, _ = reader.manifest(root / 'empty-parent', recovery=True)
    bridge_decl = validate_checkpoint_declaration(reader.document(bridge['checkpoint']), manifest=bridge)
    assert bridge_decl['history']['last_record'] == '0' and bridge_decl['witness_targets'] == decl['witness_targets']
    grandchild, _ = reader.manifest(root / 'grandchild', recovery=True)
    grand_rows = reader.history(grandchild)
    target = grand_rows[0]['target']
    assert target['anchor_history']['last_record'] == '0' and target['append_ordinal'] == '1'
    assert target['source_identity']['attempt'] == '1' and grandchild['identity']['attempt'] == '3'
    assert target['anchor_state'] == grandchild['lineage']['parent_state']
    swapped = validate_manifest(decode((root / 'swapped-page-state/manifest.json').read_bytes(), maximum=8 * 1024 * 1024))
    try:
        reader.history(swapped)
    except AssertionError:
        pass
    else:
        raise AssertionError('hash-consistent swapped catalog escaped native representation check')
    closed, _ = reader.manifest(root / 'closed-final', recovery=True)
    final_decl = validate_checkpoint_declaration(reader.document(closed['checkpoint']), manifest=closed)
    assert closed['closed'] and closed['status']['process']['state'] == 'failed'
    assert final_decl['state']['fields']['boundary']['value'] == 'final'
    assert final_decl['payloads'][0]['schema'] == 'qcl-negf-physics-v5'
    assert all(closed['status'][name]['state'] == 'not_measured' for name in
               ('convergence', 'physics', 'discretization', 'experimental'))
    print('PASS independent Python: all129 public schemas, actualcodec rank1/2/4, empty axes, literal bits/dtypes, ordered catalog negative cases, full history/outer vectors, exact tensors, frozen cutoff, multihop parent update')


if __name__ == '__main__':
    main(Path(sys.argv[1]))
