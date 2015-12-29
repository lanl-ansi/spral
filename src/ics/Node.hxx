#pragma once

#include "blas_templates.hxx"

#include "AssemblyTree.hxx"
#include "ICSExceptions.hxx"
#include "SimdVec.hxx"
#include "WorkspaceManager.hxx"

namespace spral {
namespace ics {

template <typename T>
class Node {
public:
   explicit Node(AssemblyTree::Node const& node, long loffset, int ldl)
   : node_(node), m_(node.get_nrow()), n_(node.get_ncol()), loffset_(loffset),
     ldl_(ldl)
   {}

   int get_parent_node_idx() const {
      return node_.get_parent_node().idx;
   }
   int get_idx(void) const {
      return node_.idx;
   }

   void print(T const*lval) const {
      printf("NODE %d is %d x %d (parent %d)\n", node_.idx, m_, n_,
            node_.get_parent_node().idx);
      int idx=0;
      for(auto row=node_.row_begin(); row!=node_.row_end(); ++row, ++idx) {
         printf("%d:", *row);
         for(int col=0; col<n_; ++col)
            printf(" %e", lval[loffset_ + col*ldl_ + idx]);
         printf("\n");
      }
      printf("\n");
   }

   template <typename anc_it_type>
   void factor(T const* aval, T* lval, anc_it_type anc_begin,
         anc_it_type anc_end, WorkspaceManager &memhandler) const {
      /* Setup working pointers */
      T *ldiag = &lval[loffset_];
      T *lrect = &lval[loffset_ + n_];

      /* Add A */
      for(auto ait=node_.a_to_l_begin(); ait!=node_.a_to_l_end(); ++ait) {
         int dest = ait->dest_col*ldl_ + ait->dest_row;
         ldiag[dest] += aval[ait->src];
      }

      /* Factorize diagonal block */
      int info = potrf<T>('L', n_, ldiag, ldl_);
      if(info) throw NotPositiveDefiniteException(info);

      /* Only work with generated element if it exists! */
      if(m_ - n_ > 0) { 
         /* Get workspace */
         int ldcontrib = m_ - n_;
         T *contrib = memhandler.get<T>((m_-n_)*((long) ldcontrib));
         int *map = memhandler.get<int>(node_.get_max_tree_row_index());

         /* Apply to block below diagonal */
         trsm<T>('R', 'L', 'T', 'N', m_-n_, n_, 1.0, ldiag, ldl_, lrect, ldl_);

         /* Form generated element into workspace */
         syrk<T>('L', 'N', m_-n_, n_, -1.0, lrect, ldl_, 0.0, contrib,
               ldcontrib);

         /* Distribute elements of generated element to ancestors */
         auto row_start = std::next(node_.row_begin(), n_);
         const T* contrib_ptr = contrib;
         for(auto anc_itr = anc_begin; anc_itr != anc_end; ++anc_itr) {
            int used_cols = anc_itr->add_contribution(
                  lval, row_start, node_.row_end(),
                  contrib_ptr, ldcontrib, map
                  );
            std::advance(row_start, used_cols);
            contrib_ptr += used_cols*(ldcontrib+1); // Advance to diagonal entry
         }

         /* Release workspace */
         memhandler.release<int>(map, node_.get_max_tree_row_index());
         memhandler.release<T>(contrib, (m_-n_)*((long) ldcontrib));
      }
   }

   template <typename anc_it_type>
   void forward_solve(int nrhs, T* x, int ldx, T const* lval,
         anc_it_type anc_begin, anc_it_type anc_end,
         WorkspaceManager &memhandler) const {
      /* Perform solve with diagonal block */
      T const* ldiag = &lval[loffset_];
      T* xdiag = &x[*node_.row_begin()];
      trsm<T>('L', 'L', 'N', 'N', n_, nrhs, 1.0, ldiag, ldl_, xdiag, ldx);

      if(m_-n_>0) { /* Entries below diagonal block exist */
         /* Get some workspace to calculate result in */
         int ldxlocal = m_ - n_;
         T *xlocal = memhandler.get<T>(nrhs*ldxlocal);

         /* Calculate contributions to ancestors */
         T const* lrect = &ldiag[n_];
         gemm<T>('N', 'N', m_-n_, nrhs, n_, -1.0, lrect, ldl_, xdiag, ldx, 0.0,
               xlocal, ldxlocal);

         /* Distribute contributions */
         int idx=0;
         for(auto row = node_.row_begin(); row!=node_.row_end(); ++row, ++idx)
            for(int r=0; r<nrhs; r++)
               x[r*ldx + *row] += xlocal[r*ldxlocal + idx];

         /* Release workspace */
         memhandler.release<T>(xlocal, nrhs*ldxlocal);
      }
   }

   template <typename anc_it_type>
   void backward_solve(int nrhs, T* x, int ldx, T const* lval,
         anc_it_type anc_begin, anc_it_type anc_end,
         WorkspaceManager &memhandler) const {
      /* Establish useful pointers */
      T const* ldiag = &lval[loffset_];
      T* xdiag = &x[*node_.row_begin()];

      if(m_-n_>0) { /* Entries below diagonal block exist */
         /* Get some workspace to calculate result in */
         int ldxlocal = m_ - n_;
         T *xlocal = memhandler.get<T>(nrhs*ldxlocal);

         /* Gather values from ancestors */
         int idx=0;
         for(auto row = node_.row_begin(); row!=node_.row_end(); ++row, ++idx)
            for(int r=0; r<nrhs; r++)
               xlocal[r*ldxlocal + idx] = x[r*ldx + *row] ;

         /* Apply update to xdiag[] */
         T const* lrect = &ldiag[n_];
         gemm<T>('T', 'N', n_, nrhs, m_-n_, -1.0, lrect, ldl_, xlocal,
               ldxlocal, 1.0, x, ldx);

         /* Release workspace */
         memhandler.release<T>(xlocal, nrhs*ldxlocal);
      }

      /* Perform solve with diagonal block */
      trsm<T>('L', 'L', 'T', 'N', n_, nrhs, 1.0, ldiag, ldl_, xdiag, ldx);
   }

private:
   /** Adds the contribution in contrib as per list (of rows).
    *  Uses map as workspace.
    *  \returns Number of columns found relevant. */
   template <typename it_type>
   int add_contribution(T *lval, it_type row_start, it_type row_end,
         T const* contrib, int ldcontrib, int* map) const {
      T *lptr = &lval[loffset_];
      node_.construct_row_map(map);
      for(auto src_col=row_start; src_col!=row_end; ++src_col) {
         int cidx = std::distance(row_start, src_col);
         if(! node_.contains_column(*src_col) )
            return cidx; // Done: return #cols used
         int col = map[ *src_col ]; // NB: Equal to *src_col - sptr[node]
         T const* src = &contrib[cidx*(ldcontrib+1)]; // Start on diagonal
         T *dest = &lptr[col * ldl_];
         for(auto src_row=src_col; src_row!=row_end; ++src_row) {
            int row = map[ *src_row ];
            dest[row] += *(src++);
         }
      }
      // If we reach this point, we have used all columns
      return std::distance(row_start, row_end);
   }

   /* Members */
   AssemblyTree::Node const& node_;
   int const m_;
   int const n_;
   long const loffset_;
   int const ldl_;
};

} /* namespace ics */
} /* namespace spral */
