/**
 * Email Forwarding Controller
 * Handles routes and logic for email forwarding management
 */

const express = require('express');
const router = express.Router();
const forwardModel = require('../models/forward');
const domainModel = require('../models/domain');
const { ensureAuthenticated } = require('../middleware/auth');

// Initialize forwards table
forwardModel.initForwardsTable().catch(err => {
  console.error('Failed to initialize forwards table:', err);
});

/**
 * GET /forwards - Display all email forwarding rules
 */
router.get('/', ensureAuthenticated, async (req, res) => {
  try {
    const forwards = await forwardModel.getAllForwards();
    const domains = await domainModel.getAllDomains();
    
    res.render('forwards/index', {
      title: 'Email Forwarding',
      forwards,
      domains,
      user: req.user,
      active: 'forwards'
    });
  } catch (error) {
    console.error('Error fetching forwards:', error);
    req.flash('error', 'Failed to load email forwarding rules');
    res.redirect('/dashboard');
  }
});

/**
 * GET /forwards/domain/:id - Display forwarding rules for a specific domain
 */
router.get('/domain/:id', ensureAuthenticated, async (req, res) => {
  try {
    const domainId = parseInt(req.params.id);
    const domain = await domainModel.getDomainById(domainId);
    
    if (!domain) {
      req.flash('error', 'Domain not found');
      return res.redirect('/forwards');
    }
    
    const forwards = await forwardModel.getForwardsByDomain(domainId);
    
    res.render('forwards/domain', {
      title: `Email Forwarding - ${domain.domain}`,
      forwards,
      domain,
      user: req.user,
      active: 'forwards'
    });
  } catch (error) {
    console.error(`Error fetching forwards for domain ${req.params.id}:`, error);
    req.flash('error', 'Failed to load email forwarding rules for this domain');
    res.redirect('/forwards');
  }
});

/**
 * GET /forwards/add - Display form to add a new forwarding rule
 */
router.get('/add', ensureAuthenticated, async (req, res) => {
  try {
    const domains = await domainModel.getAllDomains();
    
    // Pre-select domain if provided in query
    const preselectedDomainId = req.query.domain ? parseInt(req.query.domain) : null;
    
    res.render('forwards/add', {
      title: 'Add Email Forwarding Rule',
      domains,
      preselectedDomainId,
      user: req.user,
      active: 'forwards'
    });
  } catch (error) {
    console.error('Error loading add forwarding form:', error);
    req.flash('error', 'Failed to load form');
    res.redirect('/forwards');
  }
});

/**
 * POST /forwards/add - Handle adding a new forwarding rule
 */
router.post('/add', ensureAuthenticated, async (req, res) => {
  try {
    const { source, destination, domain_id, enabled } = req.body;
    
    // Basic validation
    if (!source || !destination || !domain_id) {
      req.flash('error', 'Please fill in all required fields');
      return res.redirect('/forwards/add');
    }
    
    // Verify domain exists
    const domain = await domainModel.getDomainById(parseInt(domain_id));
    if (!domain) {
      req.flash('error', 'Selected domain does not exist');
      return res.redirect('/forwards/add');
    }
    
    // Validate email addresses
    if (!destination.includes('@')) {
      req.flash('error', 'Destination must be a valid email address');
      return res.redirect('/forwards/add');
    }
    
    // Create the forwarding rule
    await forwardModel.createForward({
      source,
      destination,
      domain_id: parseInt(domain_id),
      enabled: enabled === 'on'
    });
    
    req.flash('success', 'Email forwarding rule created successfully');
    res.redirect('/forwards');
  } catch (error) {
    console.error('Error creating forwarding rule:', error);
    req.flash('error', `Failed to create forwarding rule: ${error.message}`);
    res.redirect('/forwards/add');
  }
});

/**
 * GET /forwards/edit/:id - Display form to edit a forwarding rule
 */
router.get('/edit/:id', ensureAuthenticated, async (req, res) => {
  try {
    const forwardId = parseInt(req.params.id);
    const forward = await forwardModel.getForwardById(forwardId);
    
    if (!forward) {
      req.flash('error', 'Forwarding rule not found');
      return res.redirect('/forwards');
    }
    
    const domains = await domainModel.getAllDomains();
    
    res.render('forwards/edit', {
      title: 'Edit Email Forwarding Rule',
      forward,
      domains,
      user: req.user,
      active: 'forwards'
    });
  } catch (error) {
    console.error(`Error loading edit form for forwarding rule ${req.params.id}:`, error);
    req.flash('error', 'Failed to load edit form');
    res.redirect('/forwards');
  }
});

/**
 * POST /forwards/edit/:id - Handle updating a forwarding rule
 */
router.post('/edit/:id', ensureAuthenticated, async (req, res) => {
  try {
    const forwardId = parseInt(req.params.id);
    const { source, destination, enabled } = req.body;
    
    // Basic validation
    if (!source || !destination) {
      req.flash('error', 'Please fill in all required fields');
      return res.redirect(`/forwards/edit/${forwardId}`);
    }
    
    // Validate destination email
    if (!destination.includes('@')) {
      req.flash('error', 'Destination must be a valid email address');
      return res.redirect(`/forwards/edit/${forwardId}`);
    }
    
    // Get current forward to ensure it exists
    const forward = await forwardModel.getForwardById(forwardId);
    if (!forward) {
      req.flash('error', 'Forwarding rule not found');
      return res.redirect('/forwards');
    }
    
    // Update the forwarding rule
    await forwardModel.updateForward(forwardId, {
      source,
      destination,
      enabled: enabled === 'on'
    });
    
    req.flash('success', 'Email forwarding rule updated successfully');
    res.redirect('/forwards');
  } catch (error) {
    console.error(`Error updating forwarding rule ${req.params.id}:`, error);
    req.flash('error', `Failed to update forwarding rule: ${error.message}`);
    res.redirect(`/forwards/edit/${req.params.id}`);
  }
});

/**
 * POST /forwards/delete/:id - Handle deleting a forwarding rule
 */
router.post('/delete/:id', ensureAuthenticated, async (req, res) => {
  try {
    const forwardId = parseInt(req.params.id);
    
    // Verify the rule exists
    const forward = await forwardModel.getForwardById(forwardId);
    if (!forward) {
      req.flash('error', 'Forwarding rule not found');
      return res.redirect('/forwards');
    }
    
    await forwardModel.deleteForward(forwardId);
    
    req.flash('success', 'Email forwarding rule deleted successfully');
    res.redirect('/forwards');
  } catch (error) {
    console.error(`Error deleting forwarding rule ${req.params.id}:`, error);
    req.flash('error', 'Failed to delete forwarding rule');
    res.redirect('/forwards');
  }
});

/**
 * POST /forwards/toggle/:id - Toggle enabled status of a forwarding rule
 */
router.post('/toggle/:id', ensureAuthenticated, async (req, res) => {
  try {
    const forwardId = parseInt(req.params.id);
    
    // Verify the rule exists
    const forward = await forwardModel.getForwardById(forwardId);
    if (!forward) {
      req.flash('error', 'Forwarding rule not found');
      return res.redirect('/forwards');
    }
    
    const updated = await forwardModel.toggleForwardStatus(forwardId);
    
    req.flash('success', `Email forwarding rule ${updated.enabled ? 'enabled' : 'disabled'} successfully`);
    res.redirect('/forwards');
  } catch (error) {
    console.error(`Error toggling forwarding rule ${req.params.id}:`, error);
    req.flash('error', 'Failed to update forwarding rule status');
    res.redirect('/forwards');
  }
});

module.exports = router;
