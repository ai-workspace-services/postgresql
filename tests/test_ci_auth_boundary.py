"""Ensure pull-request image validation needs no Vault/registry credentials."""
import ast
from pathlib import Path
import re
import unittest
import yaml

ROOT = Path(__file__).resolve().parents[1]


def event_condition(expression, event):
    expression = str(expression).removeprefix('${{').removesuffix('}}').strip()
    expression = expression.replace('github.event_name', repr(event))
    expression = re.sub(r'\btrue\b', 'True', expression)
    expression = re.sub(r'\bfalse\b', 'False', expression)
    tree = ast.parse(expression, mode='eval')
    allowed = (ast.Expression, ast.Compare, ast.Constant, ast.Eq, ast.NotEq)
    if any(not isinstance(n, allowed) for n in ast.walk(tree)):
        raise AssertionError('Review unsupported event guard before changing the authentication contract')
    return eval(compile(tree, '<event-guard>', 'eval'), {'__builtins__': {}})


class PipelineAuthBoundary(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.workflow = yaml.safe_load((ROOT / '.github/workflows/ci-pipeline.yml').read_text())

    def test_pr_skips_every_vault_and_registry_authentication_step(self):
        seen = 0
        for job in self.workflow['jobs'].values():
            for step in job.get('steps', []):
                action = step.get('uses', '')
                if action.startswith(('hashicorp/vault-action@', 'docker/login-action@')):
                    seen += 1
                    self.assertIn('if', step, step['name'])
                    self.assertFalse(event_condition(step['if'], 'pull_request'), step['name'])
                    for event in ('push', 'workflow_dispatch', 'workflow_call'):
                        self.assertTrue(event_condition(step['if'], event), (step['name'], event))
        self.assertEqual(seen, 3)

    def test_pr_builds_images_without_publishing_them(self):
        job = self.workflow['jobs']['build-and-push-images']
        self.assertNotIn('if', job)
        builds = [s for s in job['steps'] if s.get('uses', '').startswith('docker/build-push-action@')]
        self.assertEqual(len(builds), 1)
        self.assertFalse(event_condition(builds[0]['with']['push'], 'pull_request'))
        self.assertTrue(event_condition(builds[0]['with']['push'], 'push'))

    def test_pr_packages_chart_locally_and_never_pushes_it(self):
        job = self.workflow['jobs']['build-and-push-chart']
        package = next(s for s in job['steps'] if s['name'] == 'Package Chart (pull request validation)')
        publish = next(s for s in job['steps'] if s['name'] == 'Package And Push Chart')
        self.assertTrue(event_condition(package['if'], 'pull_request'))
        self.assertFalse(event_condition(publish['if'], 'pull_request'))
        self.assertTrue(event_condition(publish['if'], 'push'))


if __name__ == '__main__':
    unittest.main()
